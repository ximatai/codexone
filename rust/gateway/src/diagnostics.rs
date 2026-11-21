use std::{
    collections::BTreeMap,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use codexone_responses::{JsonValue, ProtocolError, ProviderFailure};
use codexone_websocket::{ConnectFailure, SocketEnd};
use http::HeaderMap;
use uuid::Uuid;

struct Gate<const LIMIT: u16>(Mutex<Option<(Instant, u16)>>);

impl<const LIMIT: u16> Gate<LIMIT> {
    const fn new() -> Self {
        Self(Mutex::new(None))
    }

    fn admit(&self) -> bool {
        let now = Instant::now();
        let mut state = self.0.lock().unwrap();
        let (start, used) = state.get_or_insert((now, 0));
        if now.duration_since(*start) >= Duration::from_secs(60) {
            (*start, *used) = (now, 0);
        }
        if *used == LIMIT {
            return false;
        }
        *used += 1;
        true
    }
}

static REJECTIONS: Gate<16> = Gate::new();
static SETUP: Gate<16> = Gate::new();
static CLOSED: Gate<16> = Gate::new();
static EXTENSION_LOGS: Gate<128> = Gate::new();
static MISSING_STREAM_TYPE: AtomicBool = AtomicBool::new(false);

pub fn missing_stream_type(request_id: &str) {
    if let Ok(id) = Uuid::parse_str(request_id)
        && !MISSING_STREAM_TYPE.swap(true, Ordering::Relaxed)
    {
        eprintln!(
            "Upstream stream omitted media type; SSE validation required upstream_status=200 request_id={id}"
        );
    }
}

pub fn rejection(
    request_id: &str,
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    status: Option<u16>,
) {
    let Ok(id) = Uuid::parse_str(request_id) else {
        return;
    };
    if !REJECTIONS.admit() {
        return;
    }
    let status = status.or_else(|| provider.and_then(provider_status));
    let status = status.map_or(String::new(), |value| format!(" upstream_status={value}"));
    let reason = error
        .detail
        .map_or(String::new(), |reason| format!(" reason={reason}"));
    let code = provider
        .and_then(|failure| failure.provider_error.as_ref())
        .and_then(|failure| failure.get("code").or_else(|| failure.get("type")))
        .and_then(JsonValue::as_str)
        .and_then(public_provider_code)
        .map_or(String::new(), |code| format!(" provider_code={code}"));
    eprintln!(
        "Gateway request rejected code={} status={} request_id={id}{status}{reason}{code}",
        error.code, error.status,
    );
}

fn public_provider_code(code: &str) -> Option<&'static str> {
    Some(match code {
        "unsupported_parameter" => "unsupported_parameter",
        "invalid_request_error" => "invalid_request_error",
        "invalid_api_key" => "invalid_api_key",
        "authentication_error" => "authentication_error",
        "rate_limit_exceeded" => "rate_limit_exceeded",
        "server_is_overloaded" => "server_is_overloaded",
        "model_not_found" => "model_not_found",
        "context_length_exceeded" => "context_length_exceeded",
        _ => return None,
    })
}

fn provider_status(provider: &ProviderFailure) -> Option<u16> {
    provider
        .upstream_status
        .and_then(|status| u16::try_from(status).ok())
        .filter(|status| (100..=599).contains(status))
}

pub fn websocket_setup(request_id: &str, failure: &ConnectFailure, credential: Option<i64>) {
    use ConnectFailure::*;
    let (stage, cause, status) = match failure {
        Cancelled => return,
        TransportSetup(error) => ("websocket_connect", transport_cause(*error), None),
        TimedOut => ("websocket_connect", "connect_timeout", None),
        Transport => ("websocket_connect", "connection_failed", None),
        InvalidTarget => ("websocket_connect", "invalid_target", None),
        Handshake => ("websocket_handshake", "upgrade_handshake", None),
        Rejected(failure) => (
            "websocket_handshake",
            "upstream_upgrade_rejected",
            provider_status(failure),
        ),
    };
    setup(request_id, stage, cause, status, credential);
}

pub fn http_setup(
    request_id: &str,
    failure: codexone_http_upstream::Error,
    credential: Option<i64>,
) {
    if failure != codexone_http_upstream::Error::Cancelled {
        setup(
            request_id,
            "http_request",
            transport_cause(failure),
            None,
            credential,
        );
    }
}

fn transport_cause(error: codexone_http_upstream::Error) -> &'static str {
    use codexone_http_upstream::Error::*;
    match error {
        Connect => "connection_failed",
        ConnectTimeout => "connect_timeout",
        ProxyAuthenticationRequired => "upstream_proxy_authentication_required",
        ProxyConnect => "upstream_proxy_failed",
        Tls => "tls_verification_failed",
        FirstResponseTimeout => "execution_first_response_timeout",
        ProgressTimeout => "execution_progress_timeout",
        DeadlineExceeded => "execution_deadline_exceeded",
        _ => "transport_failed",
    }
}

fn setup(
    request_id: &str,
    stage: &'static str,
    cause: &'static str,
    status: Option<u16>,
    credential: Option<i64>,
) {
    let Ok(id) = Uuid::parse_str(request_id) else {
        return;
    };
    if !SETUP.admit() {
        return;
    }
    let classification = if matches!(status, Some(401)) {
        "authentication_rejected"
    } else if status.is_some() {
        "upstream_status_observed"
    } else {
        "no_upstream_status"
    };
    let status = status.map_or(String::new(), |status| format!(" upstream_status={status}"));
    let credential = credential.map_or(String::new(), |version| {
        format!(" credential_version={version}")
    });
    eprintln!(
        "Upstream failed before first event request_id={id} stage={stage} classification={classification} cause={cause}{status}{credential}"
    );
}

pub fn websocket_close(
    request_id: &str,
    socket: SocketEnd,
    first_event: bool,
    credential: Option<i64>,
) {
    let Ok(id) = Uuid::parse_str(request_id) else {
        return;
    };
    let (reason, code) = match socket {
        SocketEnd::Close(code) => (
            "upstream_websocket_close",
            Some(code).filter(|code| (1000..=4999).contains(code)),
        ),
        SocketEnd::Eof => ("upstream_websocket_eof", None),
        _ => return,
    };
    if CLOSED.admit() {
        let code = code.map_or(String::new(), |code| {
            format!(" upstream_ws_close_code={code}")
        });
        eprintln!(
            "Gateway request rejected code=execution_indeterminate status=502 request_id={id} reason={reason}{code}"
        );
    }
    if !first_event && SETUP.admit() {
        let credential = credential.map_or(String::new(), |version| {
            format!(" credential_version={version}")
        });
        eprintln!(
            "Upstream failed before first event request_id={id} stage=websocket_turn classification=no_provider_event cause={reason}{credential}"
        );
    }
}

fn identifier(value: &str) -> Option<&str> {
    (!value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte)))
    .then_some(value)
}

#[derive(Default)]
pub(crate) struct ClientProtocolExtensions(Mutex<Entries>);

#[derive(Default)]
struct Entries {
    first_seen: BTreeMap<String, i64>,
    overflow: bool,
}

impl ClientProtocolExtensions {
    fn record(&self, name: &str) {
        let Some(name) = identifier(name) else { return };
        let mut entries = self.0.lock().unwrap();
        if entries.first_seen.contains_key(name) {
            return;
        }
        if entries.first_seen.len() == 32 {
            entries.overflow = true;
            return;
        }
        entries
            .first_seen
            .insert(name.to_owned(), crate::unix_time());
    }

    pub fn client(&self, name: &str, outcome: &'static str, client: &Client) {
        self.record(name);
        self.log(name, outcome, client);
    }

    pub fn log(&self, name: &str, outcome: &'static str, client: &Client) {
        if EXTENSION_LOGS.admit() {
            let name = identifier(name).unwrap_or("invalid");
            eprintln!(
                "Client protocol extension protocol_name={name} outcome={outcome} client_category={} client_version={}",
                client.category, client.version
            );
        }
    }

    pub fn upstream_event(&self, event: &JsonValue) {
        if !codexone_responses::EventSemantics::classify(event).recognized_type
            && let Ok(name) = codexone_responses::event_type(event)
        {
            self.upstream_name(name);
        }
    }

    pub fn upstream_name(&self, name: &str) {
        let name = format!("upstream_event.{name}");
        self.record(if name.len() <= 128 {
            &name
        } else {
            "upstream_event.long_name"
        });
    }

    /// A bounded projection for the shared attention and live overview reader.
    pub fn snapshot(&self) -> codexone_usage::ProtocolExtensions {
        let entries = self.0.lock().unwrap();
        codexone_usage::ProtocolExtensions {
            names: entries.first_seen.clone(),
            overflow: entries.overflow,
        }
    }
}

pub(crate) struct Client {
    category: &'static str,
    version: String,
}

impl Client {
    pub fn inspect(headers: &HeaderMap) -> Self {
        Self {
            category: if crate::headers::is_native(headers) {
                "codex"
            } else {
                "other"
            },
            version: headers
                .get("version")
                .map_or("unknown", |value| {
                    value
                        .to_str()
                        .ok()
                        .and_then(identifier)
                        .filter(|version| {
                            // Accept version-shaped labels and omit unrelated header values.
                            version.starts_with(|c: char| c.is_ascii_digit())
                                && version.contains('.')
                        })
                        .unwrap_or("invalid")
                })
                .to_owned(),
        }
    }
}
