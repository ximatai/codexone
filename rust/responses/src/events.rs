use crate::{
    BindingKind, JsonValue, ObjectBinding, ProtocolError, ProviderFailure, UsageConfig,
    UsageEvidence, metadata, opaque_context,
    provider_error::{
        event_provider_failure, is_explicit_rejection, numeric_field, sanitized_error,
    },
    request::valid_turn_state,
    same_text, text, text_usage, valid_id,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_wire::{SseDecoder, SsePayload};

pub const MAX_EVENT_BYTES: usize = 8_388_608;
pub const MAX_RESPONSE_BYTES: usize = 33_554_432;
pub const DONE_FRAME: &[u8] = b"data: [DONE]\n\n";
const INVALID_EVENT: ProtocolError =
    ProtocolError::new(502, "invalid_upstream_event").with_detail("upstream_event");
const INVALID_RESPONSE: ProtocolError = ProtocolError::new(502, "invalid_upstream_response");
const INVALID_TURN: ProtocolError = ProtocolError::new(502, "invalid_upstream_turn");
const INDETERMINATE: ProtocolError = ProtocolError::new(502, "execution_indeterminate");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    None,
    Acknowledgement,
    Activity,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IncompleteReason {
    MaxOutputTokens,
    MaxMessages,
    ContentFilter,
    Steered,
    Unspecified,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Terminal {
    Completed,
    Failed,
    Incomplete(IncompleteReason),
}

impl Terminal {
    fn from_event(event_type: &str, response: Option<&JsonValue>) -> Option<Self> {
        match event_type {
            "response.completed" => Some(Self::Completed),
            "response.failed" => Some(Self::Failed),
            "response.incomplete" => {
                let reason = response
                    .and_then(|v| v.get("incomplete_details"))
                    .and_then(|v| text(v, "reason"));
                Some(Self::Incomplete(match reason {
                    Some("max_output_tokens") => IncompleteReason::MaxOutputTokens,
                    Some("max_messages") => IncompleteReason::MaxMessages,
                    Some("content_filter") => IncompleteReason::ContentFilter,
                    Some("steered") => IncompleteReason::Steered,
                    _ => IncompleteReason::Unspecified,
                }))
            }
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EventSemantics {
    pub known: bool,
    pub recognized_type: bool,
    pub lifecycle: bool,
    pub terminal: bool,
    pub carries_item: bool,
    pub carries_item_id: bool,
    pub connection_metadata: bool,
    pub progress: Progress,
}

impl EventSemantics {
    pub fn classify(event: &JsonValue) -> Self {
        let event_type = text(event, "type").unwrap_or("");
        let terminal = matches!(
            event_type,
            "response.completed" | "response.failed" | "response.incomplete"
        );
        let lifecycle = terminal
            || matches!(
                event_type,
                "response.created" | "response.queued" | "response.in_progress"
            );
        let carries_item = matches!(
            event_type,
            "response.output_item.added" | "response.output_item.done"
        );
        let part = matches!(
            event_type,
            "response.content_part.added"
                | "response.content_part.done"
                | "response.reasoning_summary_part.added"
                | "response.reasoning_summary_part.done"
                | "response.output_text.annotation.added"
                | "response.output_text.done"
                | "response.function_call_arguments.done"
                | "response.custom_tool_call_input.done"
                | "response.reasoning_text.done"
                | "response.reasoning_summary_text.done"
                | "response.refusal.done"
                | "response.image_generation_call.in_progress"
                | "response.image_generation_call.generating"
                | "response.image_generation_call.completed"
                | "response.image_generation_call.partial_image"
                | "response.web_search_call.in_progress"
                | "response.web_search_call.searching"
                | "response.web_search_call.completed"
                | "response.file_search_call.in_progress"
                | "response.file_search_call.searching"
                | "response.file_search_call.completed"
                | "response.code_interpreter_call.in_progress"
                | "response.code_interpreter_call.interpreting"
                | "response.code_interpreter_call.completed"
                | "response.code_interpreter_call_code.done"
        );
        let delta = matches!(
            event_type,
            "response.output_text.delta"
                | "response.function_call_arguments.delta"
                | "response.custom_tool_call_input.delta"
                | "response.reasoning_text.delta"
                | "response.reasoning_summary_text.delta"
                | "response.refusal.delta"
                | "response.code_interpreter_call_code.delta"
        );
        let connection_metadata = matches!(
            event_type,
            "response.metadata"
                | "codex.response.metadata"
                | "rate_limits.updated"
                | "codex.rate_limits"
        ) && [
            "response",
            "response_id",
            "item",
            "item_id",
            "delta",
            "output",
        ]
        .iter()
        .all(|name| event.get(name).is_none());
        let known = lifecycle
            || carries_item
            || part
            || delta
            || connection_metadata
            || event_type == "error";
        Self {
            known,
            lifecycle,
            terminal,
            carries_item,
            carries_item_id: part || delta,
            connection_metadata,
            recognized_type: known
                || matches!(
                    event_type,
                    "response.metadata"
                        | "codex.response.metadata"
                        | "responsesapi.websocket_timing"
                        | "response.output_item.interrupted"
                ),
            progress: if terminal
                || carries_item
                || part
                || (delta && text(event, "delta").is_some_and(|delta| !delta.is_empty()))
            {
                Progress::Activity
            } else if lifecycle {
                Progress::Acknowledgement
            } else {
                Progress::None
            },
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum EventFailure {
    Protocol(ProtocolError),
    Provider(Box<ProviderFailure>),
}

impl From<ProtocolError> for EventFailure {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Delivery {
    pub bindings: Vec<ObjectBinding>,
    pub progress: Progress,
    pub terminal: Option<Terminal>,
    pub actual_service_tier: Option<String>,
    /// Apply bindings and record a failed/incomplete outcome before submitting this document.
    /// A completed outcome is recorded only after successful downstream submission.
    pub document: Option<JsonValue>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Observation {
    /// Persist in revision order before handling the delivery result. Terminal usage can survive
    /// an invalid image item, a binding failure or a downstream write failure.
    pub usage: Vec<UsageEvidence>,
    pub turn_state: Option<String>,
    pub result: Result<Delivery, EventFailure>,
}

/// Interpret one HTTP upstream attempt, with bounded incremental framing and response correlation.
/// Callers stop polling upon terminal delivery or any error, and own deadlines and settlement.
pub struct ResponseStream<'a> {
    decoder: SseDecoder,
    usage: UsageConfig<'a>,
    client_stream: bool,
    response_id: Option<String>,
    first_event: bool,
    stopped: bool,
    terminal: bool,
}

impl<'a> ResponseStream<'a> {
    pub fn new(client_stream: bool, usage: UsageConfig<'a>) -> Self {
        Self {
            decoder: SseDecoder::new(MAX_EVENT_BYTES, MAX_RESPONSE_BYTES),
            usage,
            client_stream,
            response_id: None,
            first_event: true,
            stopped: false,
            terminal: false,
        }
    }

    /// Consume at most one JSON event. Process its evidence before consuming the chunk suffix.
    /// Comments and [DONE] are consumed without yielding business evidence.
    pub fn next_event(&mut self, chunk: &mut &[u8]) -> Result<Option<Observation>, ProtocolError> {
        if self.stopped {
            return Ok(None);
        }
        while !chunk.is_empty() {
            let frame = match self.decoder.next_frame(chunk) {
                Ok(frame) => frame,
                Err(error) => {
                    self.stopped = true;
                    return Err(ProtocolError::new(502, error.code()));
                }
            };
            let Some(frame) = frame else { break };
            if let SsePayload::Json(event) = frame.payload {
                let observation = self.observe(event);
                self.terminal = observation
                    .result
                    .as_ref()
                    .is_ok_and(|delivery| delivery.terminal.is_some());
                self.stopped = self.terminal || observation.result.is_err();
                return Ok(Some(observation));
            }
        }
        Ok(None)
    }

    /// Upstream [DONE] alone conveys no execution result.
    pub fn finish(&self) -> Result<(), ProtocolError> {
        if self.terminal {
            return Ok(());
        }
        self.decoder
            .finish()
            .map_err(|e| ProtocolError::new(502, e.code()))?;
        Err(INDETERMINATE)
    }

    fn observe(&mut self, mut event: JsonValue) -> Observation {
        let mut usage = Vec::new();
        let mut turn_state = None;
        let rejected = self.first_event && explicit_event_rejection(&event);
        self.first_event = false;
        if rejected {
            usage.push(UsageEvidence::provider_rejection(
                self.usage.image.is_some(),
            ));
        }
        let result = (|| {
            let event_type = event_type(&event)?;
            if event_type == "error" {
                return Err(EventFailure::Provider(Box::new(event_provider_failure(
                    &event,
                ))));
            }
            let semantics = EventSemantics::classify(&event);
            let response = event.get("response");
            if semantics.lifecycle
                && let Some(response) = response
            {
                let id = response.get("id").and_then(valid_id).ok_or(INVALID_TURN)?;
                if self
                    .response_id
                    .as_deref()
                    .is_some_and(|previous| !same_text(previous, id))
                {
                    return Err(INVALID_TURN.into());
                }
                if self.response_id.is_none() {
                    self.response_id = Some(id.to_owned());
                }
            }
            if let Some(id) = event.get("response_id")
                && id.as_str().is_none_or(|id| {
                    self.response_id
                        .as_deref()
                        .is_some_and(|previous| !same_text(previous, id))
                })
            {
                return Err(INVALID_TURN.into());
            }
            turn_state = response_metadata_turn_state(&event).map(str::to_owned);
            let terminal = Terminal::from_event(event_type, response);
            if terminal.is_some() && !rejected {
                self.usage.observe(response, &mut usage)?;
            }
            let bindings = event_bindings(&event, semantics, self.usage.image.is_some())?;
            let actual_service_tier =
                terminal.and_then(|_| metadata(response.and_then(|v| v.get("service_tier"))));
            let document = if self.client_stream {
                sanitize_client_output(&mut event);
                Some(event)
            } else if terminal.is_some() {
                let mut document = event
                    .as_object_mut()
                    .and_then(|event| event.remove("response"))
                    .ok_or(INVALID_RESPONSE)?;
                sanitize_client_output(&mut document);
                Some(document)
            } else {
                None
            };
            Ok(Delivery {
                bindings,
                progress: semantics.progress,
                terminal,
                actual_service_tier,
                document,
            })
        })();
        Observation {
            usage,
            turn_state,
            result,
        }
    }
}

pub fn validate_upstream_media_type(
    content_type: Option<&str>,
    wire_streaming: bool,
) -> Result<(), ProtocolError> {
    if wire_streaming {
        let header = content_type.unwrap_or_default().trim();
        let media = header.split(';').next().unwrap_or_default().trim();
        if header.is_empty() || media.eq_ignore_ascii_case("text/event-stream") {
            return Ok(());
        }
        let detail = if media.eq_ignore_ascii_case("application/json") {
            "upstream_media_type_json"
        } else if media.eq_ignore_ascii_case("text/html") {
            "upstream_media_type_html"
        } else {
            "upstream_media_type_other"
        };
        return Err(ProtocolError::new(502, "invalid_upstream_content_type").with_detail(detail));
    }
    if content_type
        .is_some_and(|header| header.to_ascii_lowercase().starts_with("application/json"))
    {
        return Ok(());
    }
    Err(ProtocolError::new(502, "invalid_upstream_content_type"))
}

/// Interpret a bounded, successful HTTP JSON response. Independent compact replies retain the
/// canonical compaction document and their own ownership kind.
pub fn observe_json(body: &[u8], usage_config: UsageConfig<'_>, compact: bool) -> Observation {
    let mut usage = Vec::new();
    let result = (|| {
        let limit = if !compact && usage_config.image.is_some() {
            MAX_EVENT_BYTES
        } else {
            MAX_RESPONSE_BYTES
        };
        if body.len() > limit {
            return Err(ProtocolError::new(502, "upstream_response_too_large").into());
        }
        let mut document = JsonValue::decode(body).map_err(|_| INVALID_RESPONSE)?;
        let mut bindings = Vec::new();
        let terminal;
        if compact {
            if text(&document, "object") != Some("response.compaction") {
                return Err(ProtocolError::new(502, "invalid_upstream_compaction").into());
            }
            terminal = None;
            usage.extend(text_usage(document.get("usage"), usage_config.host));
            if let Some(id) = document.get("id").and_then(valid_id) {
                bindings.push(ObjectBinding::new(BindingKind::Compaction, id));
            }
        } else {
            terminal = match text(&document, "status") {
                Some("completed") => Some(Terminal::Completed),
                Some("failed") => Some(Terminal::Failed),
                Some("incomplete") => Terminal::from_event("response.incomplete", Some(&document)),
                _ => return Err(INDETERMINATE.into()),
            };
            // The independent upstream JSON path has no SVG author price catalog.
            let json_usage = UsageConfig {
                image: usage_config.image.map(|image| crate::ImageUsageConfig {
                    author_rates: &[],
                    ..image
                }),
                ..usage_config
            };
            json_usage.observe(Some(&document), &mut usage)?;
            let id = document
                .get("id")
                .and_then(valid_id)
                .ok_or(INVALID_RESPONSE)?;
            bindings.push(ObjectBinding::new(BindingKind::Response, id));
        }
        output_bindings(
            &document,
            !compact && usage_config.image.is_some(),
            &mut bindings,
        )?;
        let actual_service_tier = metadata(document.get("service_tier"));
        if !compact {
            sanitize_client_output(&mut document);
        }
        Ok(Delivery {
            bindings,
            progress: Progress::Activity,
            terminal,
            actual_service_tier,
            document: Some(document),
        })
    })();
    Observation {
        usage,
        turn_state: None,
        result,
    }
}

pub fn event_type(event: &JsonValue) -> Result<&str, ProtocolError> {
    text(event, "type")
        .filter(|name| {
            (1..=128).contains(&name.len())
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
        })
        .ok_or(INVALID_EVENT)
}

pub fn encode_sse_event(event: &JsonValue) -> Result<Vec<u8>, ProtocolError> {
    let event_type = event_type(event)?;
    let mut frame = format!("event: {event_type}\ndata: ").into_bytes();
    frame.extend(event.encode(true));
    frame.extend(b"\n\n");
    Ok(frame)
}

pub fn response_metadata_turn_state(event: &JsonValue) -> Option<&str> {
    if !matches!(
        text(event, "type"),
        Some("response.metadata" | "codex.response.metadata")
    ) {
        return None;
    }
    let headers = event.get("headers")?.as_object()?;
    let mut tokens = headers
        .iter()
        .filter(|(name, _)| name.eq_ignore_ascii_case("x-codex-turn-state"));
    let (_, token) = tokens.next()?;
    if tokens.next().is_some() {
        return None;
    }
    token
        .as_str()
        .or_else(|| token.as_array()?.first()?.as_str())
        .filter(|token| valid_turn_state(token))
}

fn explicit_event_rejection(event: &JsonValue) -> bool {
    if !matches!(text(event, "type"), Some("error" | "response.failed"))
        || event.get("item").is_some()
        || event.get("delta").is_some()
    {
        return false;
    }
    let response = event.get("response");
    for scope in [Some(event), response].into_iter().flatten() {
        if scope
            .get("output")
            .is_some_and(|v| !v.as_array().is_some_and(<[_]>::is_empty))
        {
            return false;
        }
    }
    if response
        .and_then(|v| v.get("usage"))
        .is_some_and(|v| v != &JsonValue::Null)
    {
        return false;
    }
    let response = response.unwrap_or(event);
    let error = response
        .get("error")
        .or_else(|| event.get("error"))
        .unwrap_or(event);
    let status = numeric_field(event, "status")
        .or_else(|| numeric_field(event, "status_code"))
        .or_else(|| numeric_field(response, "status_code"))
        .or_else(|| numeric_field(error, "status"))
        .or_else(|| numeric_field(error, "status_code"));
    is_explicit_rejection(status, Some(error))
}

fn event_bindings(
    event: &JsonValue,
    semantics: EventSemantics,
    images: bool,
) -> Result<Vec<ObjectBinding>, ProtocolError> {
    let mut bindings = Vec::new();
    if semantics.lifecycle {
        let response = event.get("response").ok_or(INVALID_RESPONSE)?;
        let id = response
            .get("id")
            .and_then(valid_id)
            .ok_or(INVALID_RESPONSE)?;
        bindings.push(ObjectBinding::new(BindingKind::Response, id));
        output_bindings(response, images, &mut bindings)?;
    } else if semantics.carries_item
        && let Some(item) = event.get("item")
    {
        item_bindings(item, images, &mut bindings)?;
    } else if images && text(event, "type") == Some("response.image_generation_call.partial_image")
    {
        let index = numeric_field(event, "partial_image_index");
        if !index.is_some_and(|i| (0..=2).contains(&i))
            || !valid_image(text(event, "partial_image_b64"), false)
        {
            return Err(ProtocolError::new(502, "invalid_upstream_image"));
        }
    }
    if semantics.carries_item_id
        && let Some(id) = event.get("item_id").and_then(valid_id)
    {
        bindings.push(ObjectBinding::new(BindingKind::Item, id));
    }
    Ok(bindings)
}

fn output_bindings(
    document: &JsonValue,
    images: bool,
    bindings: &mut Vec<ObjectBinding>,
) -> Result<(), ProtocolError> {
    for item in document
        .get("output")
        .and_then(JsonValue::as_array)
        .unwrap_or_default()
    {
        item_bindings(item, images, bindings)?;
    }
    Ok(())
}

fn item_bindings(
    item: &JsonValue,
    images: bool,
    bindings: &mut Vec<ObjectBinding>,
) -> Result<(), ProtocolError> {
    let item_type = text(item, "type").unwrap_or("");
    if let Some(id) = item.get("id").and_then(valid_id) {
        bindings.push(ObjectBinding::new(BindingKind::Item, id));
    }
    if matches!(item_type, "function_call" | "custom_tool_call")
        && let Some(call) = item.get("call_id").and_then(valid_id)
    {
        bindings.push(ObjectBinding::new(BindingKind::FunctionCall, call));
    }
    if let Some(context) = item
        .get("encrypted_content")
        .and_then(|v| opaque_context(item_type, v))
    {
        bindings.push(context);
    }
    if images
        && item_type == "image_generation_call"
        && text(item, "status") == Some("completed")
        && !valid_image(text(item, "result"), true)
    {
        return Err(ProtocolError::new(502, "invalid_upstream_image"));
    }
    Ok(())
}

fn valid_image(value: Option<&str>, nonempty: bool) -> bool {
    value.is_some_and(|encoded| {
        encoded.len() <= MAX_EVENT_BYTES
            && (!nonempty || !encoded.is_empty())
            && STANDARD.decode(encoded).is_ok()
    })
}

/// Maintain the received document and key order, repairing only known counters and errors.
pub fn sanitize_client_output(value: &mut JsonValue) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    if let Some(response) = fields.get_mut("response") {
        sanitize_client_output(response);
    }
    if let Some(error) = fields.get_mut("error")
        && error != &JsonValue::Null
    {
        *error = JsonValue::Object(sanitized_error(Some(error)).unwrap_or_default());
    }
    let Some(usage) = fields.get_mut("usage").and_then(JsonValue::as_object_mut) else {
        return;
    };
    repair(usage, &["input_tokens", "output_tokens", "total_tokens"]);
    for (key, counters) in [
        (
            "input_tokens_details",
            &["cached_tokens", "cache_write_tokens"][..],
        ),
        ("output_tokens_details", &["reasoning_tokens"][..]),
    ] {
        match usage.get_mut(key) {
            Some(JsonValue::Object(details)) => {
                repair(details, counters);
                if key == "input_tokens_details" {
                    match details.get_mut("cache_write_tokens_details") {
                        Some(JsonValue::Object(ttl)) => {
                            repair(ttl, &["ttl_30m_tokens", "ttl_12h_tokens"])
                        }
                        Some(_) => {
                            details.remove("cache_write_tokens_details");
                        }
                        None => {}
                    }
                }
            }
            Some(_) => {
                usage.remove(key);
            }
            None => {}
        }
    }
}

fn repair(fields: &mut crate::JsonObject, counters: &[&str]) {
    fields.retain(|key, value| {
        !counters.contains(&key) || value.as_i64().is_some_and(|count| count >= 0)
    });
}
