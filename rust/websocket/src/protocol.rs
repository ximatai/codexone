use codexone_responses::{
    Contract, ImageModels, JsonObject, JsonValue, Mode, PreviousTools, ProtocolError,
    ProviderFailure, Request, error_envelope,
};
use tokio_tungstenite::tungstenite::Utf8Bytes;

use crate::WS_ROUTING_BYTES;

pub(crate) const INVALID_EVENT: ProtocolError = ProtocolError::new(502, "invalid_upstream_event");
pub(crate) const INVALID_TURN: ProtocolError = ProtocolError::new(502, "invalid_upstream_turn");
pub(crate) const UNSUPPORTED_CONTROL: ProtocolError =
    ProtocolError::new(400, "unsupported_websocket_control");
pub(crate) const INDETERMINATE: ProtocolError = ProtocolError::new(502, "execution_indeterminate");
pub(crate) const DEADLINE: ProtocolError = ProtocolError::new(504, "execution_deadline_exceeded");
pub(crate) const FIRST_RESPONSE: ProtocolError =
    ProtocolError::new(504, "execution_first_response_timeout");
pub(crate) const IDLE: ProtocolError = ProtocolError::new(504, "execution_progress_timeout");
pub(crate) const TOO_LARGE: ProtocolError = ProtocolError::new(413, "conversation_too_large");

pub fn websocket_lane(document: &JsonValue) -> Result<&str, ProtocolError> {
    match document.get("stream_id") {
        None => Ok(""),
        Some(value) => value
            .as_str()
            .filter(|name| {
                (1..=256).contains(&name.len())
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
            })
            .ok_or(ProtocolError::new(400, "invalid_stream_id")),
    }
}

pub fn decode_client_message(bytes: &[u8]) -> Result<JsonValue, ProtocolError> {
    if bytes.len() > codexone_responses::MAX_REQUEST_BYTES {
        return Err(ProtocolError::new(413, "request_too_large"));
    }
    JsonValue::decode(bytes).map_err(|error| ProtocolError::new(400, error.code()))
}

pub fn parse_create(
    mut document: JsonValue,
    images: Option<ImageModels<'_>>,
    previous_tools: Option<PreviousTools<'_>>,
) -> Result<Request, ProtocolError> {
    websocket_lane(&document)?;
    let fields = document.as_object_mut().ok_or(UNSUPPORTED_CONTROL)?;
    if fields.remove("type").as_ref().and_then(JsonValue::as_str) != Some("response.create") {
        return Err(UNSUPPORTED_CONTROL);
    }
    fields.remove("stream_id");
    let mode = match fields.remove("generate") {
        Some(JsonValue::Bool(false)) => Mode::Warmup,
        None | Some(JsonValue::Bool(true)) => Mode::Generation,
        _ => return Err(UNSUPPORTED_CONTROL),
    };
    fields.insert("stream", JsonValue::Bool(true));
    Request::parse_with_previous_tools(&document.encode(false), mode, images, previous_tools)
}

pub fn create_frame(
    request: Request,
    contract: Contract,
    lane: &str,
    turn_state: Option<&str>,
) -> Result<Utf8Bytes, ProtocolError> {
    let warmup = request.mode == Mode::Warmup;
    let lite = request.uses_responses_lite;
    let mut document = request.into_upstream_document(contract, true)?;
    let fields = document.as_object_mut().expect("validated request object");
    if contract == Contract::Responses {
        fields.remove("stream");
    }
    fields.insert("type", string("response.create"));
    if lite || (contract == Contract::CodexSubscription && turn_state.is_some()) {
        if fields
            .get("client_metadata")
            .and_then(JsonValue::as_object)
            .is_none()
        {
            fields.insert("client_metadata", JsonValue::Object(JsonObject::new()));
        }
        let metadata = fields
            .get_mut("client_metadata")
            .and_then(JsonValue::as_object_mut)
            .expect("metadata object");
        if lite {
            metadata.insert(
                "ws_request_header_x_openai_internal_codex_responses_lite",
                string("true"),
            );
        }
        if let Some(turn_state) = turn_state.filter(|_| contract == Contract::CodexSubscription) {
            metadata.insert("x-codex-turn-state", string(turn_state));
        }
    }
    if warmup {
        fields.insert("generate", JsonValue::Bool(false));
    }
    if !lane.is_empty() {
        fields.insert("stream_id", string(lane));
    }
    websocket_lane(&document)?;
    Ok(encode(document))
}

pub fn native_frame(
    request: Request,
    contract: Contract,
    lane: &str,
    turn_state: Option<&str>,
) -> Result<Utf8Bytes, ProtocolError> {
    let frame = create_frame(request, contract, lane, turn_state)?;
    if frame.len() > WS_ROUTING_BYTES {
        return Err(TOO_LARGE);
    }
    Ok(frame)
}

pub(crate) fn string(value: impl Into<String>) -> JsonValue {
    JsonValue::String(value.into())
}

pub(crate) fn encode(document: JsonValue) -> Utf8Bytes {
    Utf8Bytes::try_from(document.encode(false)).expect("ordered JSON encodes as UTF-8")
}

pub(crate) fn control(kind: &str, id: &str, lane: &str) -> Utf8Bytes {
    let mut fields = JsonObject::new();
    fields.insert("type", string(kind));
    fields.insert("response_id", string(id));
    with_lane(&mut fields, lane);
    encode(JsonValue::Object(fields))
}

pub(crate) fn with_lane(fields: &mut JsonObject, lane: &str) {
    if !lane.is_empty() {
        fields.insert("stream_id", string(lane));
    }
}

pub fn websocket_error(
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    request_id: &str,
    lane: &str,
) -> Utf8Bytes {
    let envelope = error_envelope(error, provider, request_id);
    let mut fields = JsonObject::new();
    fields.insert("type", string("error"));
    fields.insert(
        "status",
        JsonValue::decode(error.status.to_string().as_bytes()).expect("numeric status"),
    );
    fields.insert(
        "error",
        envelope.get("error").expect("error envelope").clone(),
    );
    if let Some(retry_after) = provider.and_then(|failure| failure.client_retry_after.as_ref())
        && fields
            .get("error")
            .and_then(|error| error.get("headers"))
            .is_none()
    {
        let mut headers = JsonObject::new();
        headers.insert("retry-after", string(retry_after));
        fields.insert("headers", JsonValue::Object(headers));
    }
    with_lane(&mut fields, lane);
    encode(JsonValue::Object(fields))
}
