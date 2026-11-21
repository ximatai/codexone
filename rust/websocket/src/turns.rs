use std::collections::{HashMap, VecDeque};

use codexone_responses::{
    EventFailure, EventSemantics, JsonValue, MAX_RESPONSE_BYTES, Progress, ProtocolError,
    ProviderFailure, Rates, ResponseStream, UsageConfig, event_type,
};
use tokio::time::Instant;

use crate::{
    ExecutionBudget,
    protocol::{FIRST_RESPONSE, IDLE, INVALID_EVENT, INVALID_TURN, encode, websocket_lane},
};

const HISTORY_LIMIT: usize = 1024;

pub(crate) struct Turns {
    pub active: HashMap<String, Turn>,
    ended: HashMap<String, String>,
    history: VecDeque<String>,
}

pub(crate) struct Turn {
    pub deadline: Instant,
    pub sent: Option<Instant>,
    pub last_progress: Option<Instant>,
    pub response_id: Option<String>,
    pub created: bool,
    pub interrupted: bool,
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
            last_progress: None,
            response_id: None,
            created: false,
            interrupted: false,
            processed: false,
            unattributed: false,
            warmup,
            bytes: 0,
        }
    }

    pub fn expiry(&self, budget: ExecutionBudget) -> (Instant, ProtocolError) {
        let phase = if let Some(progress) = self.last_progress {
            Some((progress + budget.idle, IDLE))
        } else {
            self.sent
                .map(|sent| (sent + budget.first_response, FIRST_RESPONSE))
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
            self.ended.insert(id.clone(), lane.to_owned());
            self.history.push_back(id.clone());
            if self.history.len() > HISTORY_LIMIT {
                self.ended
                    .remove(&self.history.pop_front().expect("oldest id"));
            }
        }
        Some(turn)
    }

    pub fn interrupt(&mut self, id: &str, lane: Option<&str>, require_created: bool) -> Interrupt {
        let owner = self.active.iter_mut().find(|(owner, turn)| {
            (!require_created || turn.created)
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
            return Err(INVALID_TURN);
        }
        let identity = correlated.or(embedded);
        if let Some(owner) = identity.and_then(|identity| self.ended.get(identity)) {
            return Ok(if kind == "response.created" {
                Route::Ignore
            } else {
                Route::Detached(owner.clone())
            });
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
        let has_owner = self.active.contains_key(&lane);
        if !semantics.connection_metadata
            && (!has_owner
                || (owner.is_none()
                    && !explicit_lane
                    && identity.is_some()
                    && !semantics.lifecycle))
        {
            for turn in self.active.values_mut() {
                turn.processed = true;
                turn.unattributed = true;
            }
        }
        let Some(turn) = self.active.get_mut(&lane) else {
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
                return Err(INVALID_TURN);
            }
            if first_lifecycle {
                turn.response_id = Some(identity.to_owned());
            }
            turn.created |= kind == "response.created";
        } else if correlated.is_some()
            && turn.response_id.is_some()
            && correlated != turn.response_id.as_deref()
        {
            return Err(INVALID_TURN);
        } else if turn.response_id.is_none()
            && kind != "error"
            && (correlated.is_some()
                || (kind.starts_with("response.") && !semantics.connection_metadata))
        {
            turn.unattributed = true;
            return Ok(Route::Ignore);
        }

        if turn.warmup
            && kind != "error"
            && !semantics.connection_metadata
            && (!semantics.lifecycle || response.is_some_and(has_output))
        {
            return Err(ProtocolError::new(502, "invalid_upstream_warmup"));
        }
        turn.bytes = turn.bytes.saturating_add(bytes);
        if turn.bytes > MAX_RESPONSE_BYTES {
            return Err(ProtocolError::new(502, "upstream_response_too_large"));
        }
        if first_lifecycle || semantics.progress == Progress::Activity {
            turn.last_progress = Some(Instant::now());
        }
        Ok(Route::Turn {
            lane,
            terminal: semantics.terminal,
            provider_error: kind == "error",
        })
    }
}

fn has_output(response: &JsonValue) -> bool {
    response
        .get("output")
        .is_some_and(|output| !output.as_array().is_some_and(<[_]>::is_empty))
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
