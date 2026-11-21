use std::{
    collections::BTreeMap,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use codexone_execution::{ExecutionService, GovernanceWork, Mode};
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
static EXTENSION_LOGS: Gate<128> = Gate::new();
static MISSING_STREAM_TYPE: AtomicBool = AtomicBool::new(false);

fn safe_request_id(value: &str) -> Option<&str> {
    (value.len() == 36 && Uuid::parse_str(value).is_ok()).then_some(value)
}

pub fn missing_stream_type(request_id: &str) {
    if let Some(id) = safe_request_id(request_id)
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
    rejection_with_selection(request_id, error, provider, status, None);
}

pub fn rejection_with_selection(
    request_id: &str,
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    status: Option<u16>,
    selection: Option<&RequestSelection>,
) {
    let Some(id) = safe_request_id(request_id) else {
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
    let selection = selection
        .filter(|_| {
            matches!(
                error.code,
                "model_not_allowed" | "reasoning_effort_not_allowed"
            )
        })
        .map_or_else(String::new, RequestSelection::log_fields);
    eprintln!(
        "warning codexone.protocol: Protocol request rejected code={} status={}{selection} request_id={id}{status}{reason}{code}",
        error.code, error.status,
    );
}

#[derive(Default)]
pub struct Rejection {
    pub mode: Mode,
    pub selection: Option<RequestSelection>,
    pub admitted: bool,
}

impl Rejection {
    pub fn inspect(
        &mut self,
        request: &codexone_responses::Request,
        models: &[codexone_config::Model],
    ) {
        self.mode = match request.mode {
            codexone_responses::Mode::Generation => Mode::Generation,
            codexone_responses::Mode::Compact => Mode::Compact,
            codexone_responses::Mode::Warmup => Mode::Warmup,
            codexone_responses::Mode::Priming => Mode::Priming,
        };
        self.selection = Some(RequestSelection::inspect(request, models));
    }

    pub async fn record(
        &self,
        execution: &ExecutionService,
        request_id: &str,
        key_id: &str,
        error: ProtocolError,
    ) {
        let (failure, reason) = match error.code {
            "invalid_api_key" | "api_key_expired" => return,
            "model_not_allowed" => ("model_not_allowed", Some("model_not_allowed")),
            "reasoning_effort_not_allowed" => (
                "invalid_request",
                Some(if error.detail.is_some() {
                    "reasoning_effort_not_allowed"
                } else {
                    self.selection.as_ref().map_or(
                        "reasoning_effort_not_allowed",
                        RequestSelection::effort_reason,
                    )
                }),
            ),
            "unsupported_backend_parameter" => ("invalid_request", error.detail),
            "conversation_too_large" => ("invalid_request", Some("conversation_too_large")),
            "unsupported_websocket_control" | "invalid_websocket_lane" => return,
            "unknown_or_ambiguous_object" => ("object_unavailable", None),
            "account_unavailable" => ("account_unavailable", Some("account_dispatch_unavailable")),
            "continuation_owner_unavailable" => (
                "account_unavailable",
                Some("continuation_owner_unavailable"),
            ),
            "maintenance_required" => ("account_unavailable", None),
            "storage_pressure" => ("storage_unavailable", None),
            "capacity_exhausted"
            | "capacity_exceeded"
            | "account_concurrency_exceeded"
            | "quota_or_policy_denied" => ("local_capacity", None),
            "execution_deadline_exceeded" => ("deadline_exceeded", None),
            "invalid_turn_state" => ("invalid_request", Some("invalid_turn_state")),
            "conflicting_turn_state" => ("invalid_request", Some("conflicting_turn_state")),
            "unsupported_client_metadata" => ("invalid_request", Some("invalid_client_metadata")),
            _ if matches!(error.status, 400 | 408 | 413 | 415) => {
                ("invalid_request", Some("invalid_request"))
            }
            _ => return,
        };
        if safe_request_id(request_id).is_none() || self.admitted {
            return;
        }
        let request_id = request_id.to_owned();
        let key_id = key_id.to_owned();
        let model = self
            .selection
            .as_ref()
            .and_then(|value| value.catalog_model.clone());
        let effort = self.selection.as_ref().map(|value| {
            if reason == Some("reasoning_effort_legacy_field") {
                value.legacy_effort.unwrap_or(value.effort)
            } else {
                value.effort
            }
        });
        let mode = match self.mode {
            Mode::Generation => "generation",
            Mode::Compact => "compact",
            Mode::Warmup => "warmup",
            Mode::Priming => "priming",
        };
        // Optional work drops on pressure or a full queue. SQL errors remain local to
        // this best-effort diagnostic and never consume the execution reserve.
        let _ = execution
            .governance_command(GovernanceWork::Optional, move |db, now, _| {
                let tx = db.begin_immediate().ok()?;
                let seen: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM attempts WHERE request_id = ?1)
                         OR EXISTS(SELECT 1 FROM request_diagnostics WHERE request_id = ?1)",
                    [&request_id],
                    |row| row.get(0),
                ).ok()?;
                if seen {
                    return Some(());
                }
                tx.execute("DELETE FROM request_diagnostics WHERE at_epoch < ?1", [now - 30 * 86400]).ok()?;
                tx.execute(
                    "DELETE FROM request_diagnostics WHERE request_id IN (
                         SELECT request_id FROM request_diagnostics
                         ORDER BY at_epoch DESC, request_id DESC LIMIT -1 OFFSET 9999)",
                    [],
                ).ok()?;
                tx.execute(
                    "INSERT INTO request_diagnostics(request_id,at_epoch,key_id,model,mode,failure,reason,reasoning_effort)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
                    rusqlite::params![request_id, now, key_id, model, mode, failure, reason, effort],
                ).ok()?;
                tx.commit().ok()
            })
            .await;
    }
}

pub struct RequestSelection {
    catalog_model: Option<String>,
    public_model: Option<String>,
    effort: &'static str,
    legacy_effort: Option<&'static str>,
}

impl RequestSelection {
    fn inspect(request: &codexone_responses::Request, models: &[codexone_config::Model]) -> Self {
        let model = identifier(&request.model);
        let catalog_model = model
            .filter(|id| models.iter().any(|model| model.id == *id))
            .map(str::to_owned);
        let public_model = model.filter(|id| public_model_id(id)).map(str::to_owned);
        let document = request.document();
        let effort = match document.get("reasoning") {
            None | Some(JsonValue::Null) => "missing",
            Some(JsonValue::Object(object)) => object.get("effort").map_or("missing", effort_label),
            _ => "invalid",
        };
        Self {
            catalog_model,
            public_model,
            effort,
            legacy_effort: document.get("reasoning_effort").map(effort_label),
        }
    }

    fn effort_reason(&self) -> &'static str {
        match (self.legacy_effort, self.effort) {
            (Some(_), _) => "reasoning_effort_legacy_field",
            (_, "missing") => "reasoning_effort_missing",
            (_, "invalid") => "reasoning_effort_invalid",
            _ => "reasoning_effort_not_allowed",
        }
    }

    fn log_fields(&self) -> String {
        let model = self
            .catalog_model
            .as_deref()
            .or(self.public_model.as_deref())
            .unwrap_or("unrecognized");
        let mut fields = format!(
            " requested_model={model} requested_reasoning_effort={}",
            self.effort
        );
        if let Some(legacy) = self.legacy_effort {
            fields.push_str(&format!(" legacy_reasoning_effort={legacy}"));
        }
        fields
    }
}

fn public_model_id(id: &str) -> bool {
    fn segment(value: &str) -> bool {
        !value.is_empty()
            && value.len() <= 16
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    }
    if id.len() > 64 {
        return false;
    }
    let mut segments = id.split(['-', '.']);
    match segments.next().unwrap_or_default().as_bytes() {
        b"gpt" | b"chatgpt" | b"codex" => {
            id.as_bytes().get(id.find(['-', '.']).unwrap_or(id.len())) == Some(&b'-')
                && segments.next().is_some_and(segment)
                && segments.all(segment)
        }
        [b'o', b'1'..=b'9'] => segments.all(segment),
        _ => false,
    }
}

fn effort_label(value: &JsonValue) -> &'static str {
    match value.as_str() {
        Some("none") => "none",
        Some("minimal") => "minimal",
        Some("low") => "low",
        Some("medium") => "medium",
        Some("high") => "high",
        Some("xhigh") => "xhigh",
        Some("max") => "max",
        Some("ultra") => "ultra",
        _ => "invalid",
    }
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
        TransportSetup(error) => (
            "websocket_connect",
            transport_cause(*error),
            transport_status(*error),
        ),
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
            transport_status(failure),
            credential,
        );
    }
}

pub fn http_response(request_id: &str, failure: &ProviderFailure, credential: Option<i64>) {
    setup(
        request_id,
        "http_response",
        failure.protocol.detail.unwrap_or(failure.protocol.code),
        provider_status(failure),
        credential,
    );
}

fn transport_status(error: codexone_http_upstream::Error) -> Option<u16> {
    (error == codexone_http_upstream::Error::ProxyAuthenticationRequired).then_some(407)
}

fn transport_cause(error: codexone_http_upstream::Error) -> &'static str {
    use codexone_http_upstream::Error::*;
    match error {
        Connect => "connection_failed",
        ConnectTimeout => "connect_timeout",
        ProxyAuthenticationRequired => "upstream_proxy_authentication_required",
        ProxyConnect => "upstream_proxy_failed",
        Tls => "tls_verification_failed",
        IncompleteResponseHeaders => "upstream_response_headers_incomplete",
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
    let Some(id) = safe_request_id(request_id) else {
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
        "warning codexone.protocol: Upstream failed before first event request_id={id} stage={stage} classification={classification} cause={cause}{status}{credential}"
    );
}

pub fn websocket_close(
    request_id: &str,
    socket: SocketEnd,
    first_event: bool,
    credential: Option<i64>,
) {
    let Some(id) = safe_request_id(request_id) else {
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
    if REJECTIONS.admit() {
        let code = code.map_or(String::new(), |code| {
            format!(" upstream_ws_close_code={code}")
        });
        eprintln!(
            "warning codexone.protocol: Protocol request rejected code=execution_indeterminate status=502 request_id={id} reason={reason}{code}"
        );
    }
    if !first_event && SETUP.admit() {
        let credential = credential.map_or(String::new(), |version| {
            format!(" credential_version={version}")
        });
        eprintln!(
            "warning codexone.protocol: Upstream failed before first event request_id={id} stage=websocket_turn classification=no_provider_event cause={reason}{credential}"
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
                            version.contains('.')
                                && version.split('.').all(|part| {
                                    !part.is_empty()
                                        && part.bytes().all(|byte| byte.is_ascii_digit())
                                })
                        })
                        .unwrap_or("invalid")
                })
                .to_owned(),
        }
    }
}
