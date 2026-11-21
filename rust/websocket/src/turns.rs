use std::{
    collections::{HashMap, VecDeque},
    time::Duration,
};

use codexone_responses::{
    BindingKind, EventFailure, EventSemantics, JsonValue, MAX_RESPONSE_BYTES, Progress,
    ProtocolError, ProviderFailure, Rates, ResponseStream, UsageConfig, correlated_bindings,
    event_type,
};
use tokio::time::Instant;

use crate::{
    ExecutionBudget,
    protocol::{FIRST_RESPONSE, IDLE, INVALID_EVENT, INVALID_TURN, encode, websocket_lane},
};

const HISTORY_LIMIT: usize = 1024;
const WEBSOCKET_TIMING: &str = "responsesapi.websocket_timing";

pub(crate) struct Turns {
    pub active: HashMap<String, Turn>,
    ended: HashMap<String, EndedTurn>,
    history: VecDeque<String>,
}

struct EndedTurn {
    lane: String,
    warmup: bool,
}

pub(crate) struct Turn {
    pub deadline: Instant,
    pub sent: Option<Instant>,
    pub first_response: Option<Duration>,
    pub last_progress: Option<Instant>,
    pub response_id: Option<String>,
    pub created: bool,
    pub interrupted: bool,
    pub provider_done: bool,
    pub processed: bool,
    pub unattributed: bool,
    pub warmup: bool,
    pub bytes: usize,
}

impl Turn {
    pub fn new(deadline: Instant, warmup: bool) -> Self {
        Self {
            deadline,
            sent: None,
            first_response: None,
            last_progress: None,
            response_id: None,
            created: false,
            interrupted: false,
            provider_done: false,
            processed: false,
            unattributed: false,
            warmup,
            bytes: 0,
        }
    }

    pub fn expiry(&self, budget: ExecutionBudget) -> (Instant, ProtocolError) {
        let phase = if self.provider_done {
            None
        } else if let Some(progress) = self.last_progress {
            Some((progress + budget.idle, IDLE))
        } else {
            self.sent.map(|sent| {
                (
                    sent + self.first_response.unwrap_or(budget.first_response),
                    FIRST_RESPONSE,
                )
            })
        };
        phase
            .filter(|(time, _)| *time < self.deadline)
            .unwrap_or((self.deadline, crate::protocol::DEADLINE))
    }
}

pub(crate) enum Route {
    Ignore,
    Detached(String),
    Turn {
        lane: String,
        terminal: bool,
        provider_error: bool,
        warmup_timing: bool,
    },
}

impl Turns {
    pub fn new() -> Self {
        Self {
            active: HashMap::new(),
            ended: HashMap::new(),
            history: VecDeque::new(),
        }
    }

    pub fn remove(&mut self, lane: &str, remember: bool) -> Option<Turn> {
        let turn = self.active.remove(lane)?;
        if remember && let Some(id) = &turn.response_id {
            self.remember(id.clone(), lane, turn.warmup);
        }
        Some(turn)
    }

    fn remember(&mut self, id: String, lane: &str, warmup: bool) {
        if self.ended.contains_key(&id) {
            return;
        }
        self.ended.insert(
            id.clone(),
            EndedTurn {
                lane: lane.to_owned(),
                warmup,
            },
        );
        self.history.push_back(id);
        if self.history.len() > HISTORY_LIMIT {
            self.ended
                .remove(&self.history.pop_front().expect("oldest id"));
        }
    }

    pub fn interrupt(&mut self, id: &str, lane: Option<&str>, require_created: bool) -> Interrupt {
        let owner = self.active.iter_mut().find(|(owner, turn)| {
            !turn.provider_done
                && (!require_created || turn.created)
                && turn.response_id.as_deref() == Some(id)
                && lane.is_none_or(|lane| lane == *owner)
        });
        match owner {
            Some((_, turn)) if turn.interrupted => Interrupt::Duplicate,
            Some((owner, turn)) => {
                turn.interrupted = true;
                Interrupt::Send(owner.clone())
            }
            None => Interrupt::Missing,
        }
    }

    pub fn observe(&mut self, document: &JsonValue, bytes: usize) -> Result<Route, ProtocolError> {
        let kind = event_type(document)?;
        let semantics = EventSemantics::classify(document);
        let is_timing = kind == WEBSOCKET_TIMING;
        let supplied_lane = websocket_lane(document)
            .map_err(|_| ProtocolError::new(502, "invalid_upstream_lane"))?;
        let explicit_lane = document.get("stream_id").is_some();
        let response = document.get("response");
        let embedded = response
            .and_then(|response| response.get("id"))
            .and_then(id);
        let correlated = match document.get("response_id") {
            Some(value) => Some(id(value).ok_or(INVALID_TURN)?),
            None => None,
        };
        if semantics.lifecycle
            && let (Some(embedded), Some(correlated)) = (embedded, correlated)
            && embedded != correlated
        {
            return Err(INVALID_TURN.with_detail("upstream_turn_response_id"));
        }
        let identity = correlated.or(embedded);
        if let Some(identity) = identity
            && let Some(owner) = self.ended.get(identity)
        {
            // A detached frame cannot go through the attempt's output binding barrier.
            // A repeated lifecycle frame can only carry the already known response.
            let has_unbound_output = semantics.carries_item
                || semantics.carries_item_id
                || (semantics.lifecycle
                    && !correlated_bindings(document, false).is_ok_and(|bindings| {
                        matches!(bindings.as_slice(), [binding]
                            if binding.kind == BindingKind::Response && binding.raw_id == identity)
                    }));
            if kind == "response.created"
                || has_unbound_output
                || (owner.warmup && is_timing && has_timing_business_members(document))
            {
                return Ok(Route::Ignore);
            }
            return Ok(Route::Detached(owner.lane.clone()));
        }
        let owner = identity.and_then(|identity| {
            self.active.iter().find_map(|(lane, turn)| {
                (turn.response_id.as_deref() == Some(identity)).then_some(lane.as_str())
            })
        });
        if let Some(owner) = owner {
            if matches!(
                kind,
                "response.interrupt.accepted" | "response.interrupt.failed"
            ) {
                return Ok(Route::Detached(owner.to_owned()));
            }
            if explicit_lane && owner != supplied_lane {
                return Err(INVALID_TURN);
            }
        }
        let lane = owner.unwrap_or(supplied_lane).to_owned();
        let has_owner = self
            .active
            .get(&lane)
            .is_some_and(|turn| !turn.provider_done);
        if !semantics.connection_metadata
            && (!has_owner
                || (owner.is_none()
                    && !explicit_lane
                    && identity.is_some()
                    && !semantics.lifecycle))
        {
            for turn in self.active.values_mut().filter(|turn| !turn.provider_done) {
                turn.processed = true;
                turn.unattributed = true;
            }
        }
        let Some(turn) = self
            .active
            .get_mut(&lane)
            .filter(|turn| !turn.provider_done)
        else {
            return if semantics.lifecycle {
                Err(INVALID_TURN.with_detail("upstream_turn_unadmitted"))
            } else {
                Ok(Route::Ignore)
            };
        };
        if !semantics.connection_metadata {
            turn.processed = true;
        }

        let first_lifecycle = turn.response_id.is_none() && semantics.lifecycle;
        if semantics.lifecycle {
            let identity = embedded.ok_or(INVALID_TURN)?;
            if turn
                .response_id
                .as_deref()
                .is_some_and(|expected| expected != identity)
            {
                return Err(if semantics.terminal {
                    INVALID_TURN.with_detail("upstream_turn_response_id")
                } else {
                    INVALID_TURN.with_detail("upstream_turn_unadmitted")
                });
            }
            if first_lifecycle {
                turn.response_id = Some(identity.to_owned());
            }
            turn.created |= kind == "response.created";
        } else if correlated.is_some()
            && turn.response_id.is_some()
            && correlated != turn.response_id.as_deref()
        {
            return Err(INVALID_TURN.with_detail("upstream_turn_response_id"));
        } else if turn.response_id.is_none()
            && kind != "error"
            && (correlated.is_some()
                || (kind.starts_with("response.") && !semantics.connection_metadata))
        {
            turn.unattributed = true;
            return Ok(Route::Ignore);
        }

        let warmup = turn.warmup;
        let warmup_timing = warmup && is_timing && !has_timing_business_members(document);
        if warmup
            && kind != "error"
            && !semantics.connection_metadata
            && !warmup_timing
            && let Some(reason) = warmup_rejection(kind, semantics, response)
        {
            return Err(ProtocolError::new(502, "invalid_upstream_warmup").with_detail(reason));
        }
        turn.bytes = turn.bytes.saturating_add(bytes);
        if turn.bytes > MAX_RESPONSE_BYTES {
            return Err(ProtocolError::new(502, "upstream_response_too_large"));
        }
        if first_lifecycle || semantics.progress == Progress::Activity {
            turn.last_progress = Some(Instant::now());
        }
        let terminal = semantics.terminal;
        let provider_error = kind == "error";
        if terminal || provider_error {
            turn.provider_done = true;
            if let Some(id) = turn.response_id.clone() {
                self.remember(id, &lane, warmup);
            }
        }
        Ok(Route::Turn {
            lane,
            terminal,
            provider_error,
            warmup_timing,
        })
    }
}

fn warmup_rejection(
    kind: &str,
    semantics: EventSemantics,
    response: Option<&JsonValue>,
) -> Option<&'static str> {
    if !semantics.lifecycle {
        return Some(match kind {
            "response.metadata" | "codex.response.metadata" => "warmup_response_metadata",
            WEBSOCKET_TIMING => "warmup_websocket_timing",
            _ if semantics.carries_item || semantics.carries_item_id => "warmup_generated_event",
            _ => "warmup_non_lifecycle_event",
        });
    }
    match response.and_then(|response| response.get("output")) {
        None | Some(JsonValue::Null) => None,
        Some(JsonValue::Array(items)) if items.is_empty() => None,
        Some(JsonValue::Array(_)) => Some("warmup_nonempty_output"),
        Some(_) => Some("warmup_invalid_output"),
    }
}

fn has_timing_business_members(document: &JsonValue) -> bool {
    // These are business or control members at their protocol positions. The
    // official client can read headers and safety_buffering before event-kind
    // dispatch. Leave opaque telemetry subtrees alone.
    [
        "headers",
        "safety_buffering",
        "response",
        "usage",
        "error",
        "output",
        "item",
        "item_id",
        "call_id",
        "part",
        "delta",
        "text",
        "input",
        "model",
        "tools",
        "generate",
    ]
    .iter()
    .any(|key| document.get(key).is_some())
}

fn id(value: &JsonValue) -> Option<&str> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 256)
}

pub(crate) enum Interrupt {
    Send(String),
    Duplicate,
    Missing,
}

pub(crate) fn decode_event(text: &[u8]) -> Result<JsonValue, ProtocolError> {
    JsonValue::decode(text).map_err(|_| INVALID_EVENT)
}

/// Reuse the Responses error classifier with the same SSE event semantics and normalization.
pub(crate) fn provider_failure(event: &JsonValue) -> ProviderFailure {
    let event = encode(event.clone());
    let mut parser = ResponseStream::new(
        true,
        UsageConfig {
            host: Rates {
                input_micros_per_million: 0,
                output_micros_per_million: 0,
            },
            image: None,
        },
    );
    for mut chunk in [b"data: ".as_slice(), event.as_bytes(), b"\n\n".as_slice()] {
        if let Ok(Some(observation)) = parser.next_event(&mut chunk)
            && let Err(EventFailure::Provider(failure)) = observation.result
        {
            return *failure;
        }
    }
    ProviderFailure {
        protocol: ProtocolError::new(502, "upstream_rejected"),
        upstream_status: None,
        provider_error: None,
        client_retry_after: None,
        cooldown_seconds: None,
        explicit_rejection: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warmup_timing_consumes_budget_without_refreshing_progress() {
        let mut turns = Turns::new();
        let deadline = Instant::now() + Duration::from_secs(60);
        turns
            .active
            .insert(String::new(), Turn::new(deadline, true));
        let timing = decode_event(
            br#"{"type":"responsesapi.websocket_timing","timing_metrics":{"response":{"id":"synthetic"}}}"#,
        )
        .unwrap();

        assert!(matches!(
            turns.observe(&timing, 128),
            Ok(Route::Turn {
                warmup_timing: true,
                terminal: false,
                ..
            })
        ));
        assert!(turns.active[""].processed);
        assert!(turns.active[""].response_id.is_none());
        assert!(turns.active[""].last_progress.is_none());

        let created = decode_event(
            br#"{"type":"response.created","response":{"id":"resp_warmup","output":[]}}"#,
        )
        .unwrap();
        turns.observe(&created, 128).unwrap();
        let last_progress = turns.active[""].last_progress.unwrap();

        let event_bytes = codexone_responses::MAX_EVENT_BYTES;
        for _ in 0..(MAX_RESPONSE_BYTES / event_bytes - 1) {
            turns.observe(&timing, event_bytes).unwrap();
        }
        let remaining = MAX_RESPONSE_BYTES - turns.active[""].bytes;
        assert!(remaining <= event_bytes);
        turns.observe(&timing, remaining).unwrap();
        assert_eq!(turns.active[""].last_progress, Some(last_progress));
        assert!(matches!(
            turns.observe(&timing, 128),
            Err(error) if error.code == "upstream_response_too_large"
        ));
    }
}
