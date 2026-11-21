//! Management routes over complete, bounded HTTP requests. The product owns the listener.

mod assets;
mod sessions;

use std::net::IpAddr;
use std::num::NonZeroU16;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use bytes::Bytes;
use codexone_config::AdminWebBundle;
use http::header::{CACHE_CONTROL, CONNECTION, CONTENT_LENGTH, CONTENT_TYPE, SET_COOKIE};
use http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode};
use serde::Serialize;
use serde_json::json;
use uuid::Builder;

use assets::Assets;
use sessions::Sessions;

/// The ingress must enforce these limits before dispatch and during the socket write.
pub const MAX_CONNECTIONS: usize = 32;
pub const MAX_REQUEST_BYTES: usize = 8 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
pub const REQUEST_READ_DEADLINE: Duration = Duration::from_secs(10);
pub const RESPONSE_WRITE_DEADLINE: Duration = Duration::from_secs(5);

#[derive(Serialize)]
pub struct ReadinessCheck {
    pub name: String,
    pub ready: bool,
}

pub struct ReadinessReport {
    pub checks: Vec<ReadinessCheck>,
}

impl ReadinessReport {
    pub fn unconfigured() -> Self {
        Self {
            checks: ["execution_store", "upstream_accounts", "authorization"]
                .into_iter()
                .map(|name| ReadinessCheck {
                    name: name.into(),
                    ready: false,
                })
                .collect(),
        }
    }

    pub fn is_ready(&self) -> bool {
        !self.checks.is_empty() && self.checks.iter().all(|check| check.ready)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SystemStatus<'a> {
    transport_mode: &'static str,
    service: &'static str,
    ready: bool,
    checks: &'a [ReadinessCheck],
}

pub struct AdminRouter {
    sessions: Option<Sessions>,
    assets: Option<Assets>,
    lan_http: bool,
}

impl AdminRouter {
    /// Pass the actual loopback listener port and the validated origin/digest and bundle
    /// from `codexone_config::Configuration`. The router belongs to that listener lifetime.
    pub fn new(
        bound_port: NonZeroU16,
        listen_address: Option<IpAddr>,
        admin_digest: Option<[u8; 32]>,
        admin_origin: Option<&str>,
        web_bundle: Option<AdminWebBundle>,
    ) -> Self {
        let sessions = admin_digest.map(|digest| Sessions::new(digest, admin_origin, bound_port));
        Self {
            lan_http: listen_address.is_some() || sessions.as_ref().is_some_and(Sessions::lan_http),
            sessions,
            assets: web_bundle.map(Assets::new),
        }
    }

    /// Returns `None` when this request belongs to a route outside this crate.
    /// Readiness is fetched only for the ready and system endpoints.
    pub async fn route(
        &self,
        request: &Request<Bytes>,
        readiness: impl AsyncFnOnce() -> ReadinessReport,
    ) -> Option<Response<Bytes>> {
        if request.body().len() > MAX_REQUEST_BYTES {
            return Some(request_too_large());
        }
        let mut segments = request
            .uri()
            .path()
            .split('/')
            .filter(|segment| !segment.is_empty());
        let path = (segments.next(), segments.next(), segments.next());
        if path.2.is_some() {
            return None;
        }
        let head = request.method() == Method::HEAD;
        let read = head || request.method() == Method::GET;
        let mut response = match (path.0, path.1) {
            (Some("api"), Some("session")) => self.sessions.as_ref()?.route(request)?,
            (Some("health"), Some("live")) if read => json_response(
                StatusCode::OK,
                "application/json; charset=utf-8",
                &json!({"status": "alive"}),
            ),
            (Some("health"), Some("ready")) | (Some("api"), Some("system")) if read => {
                let report = readiness().await;
                let ready = report.is_ready();
                let health = path.0 == Some("health");
                let status = if health && !ready {
                    StatusCode::SERVICE_UNAVAILABLE
                } else {
                    StatusCode::OK
                };
                json_response(
                    status,
                    "application/json; charset=utf-8",
                    &SystemStatus {
                        transport_mode: if !health && self.lan_http {
                            "lan_http"
                        } else {
                            "loopback"
                        },
                        service: "codexone",
                        ready,
                        checks: &report.checks,
                    },
                )
            }
            (None | Some("index.html"), None) if read => self.assets.as_ref()?.index(),
            (Some("assets"), Some(name)) if read => self.assets.as_ref()?.asset(name)?,
            _ => return None,
        };
        if head {
            let length = std::mem::take(response.body_mut()).len();
            response
                .headers_mut()
                .insert(CONTENT_LENGTH, HeaderValue::from(length));
        }
        Some(response)
    }

    /// Invalidates browser sessions for the current listener. New login remains possible.
    pub fn revoke_sessions(&self) {
        if let Some(sessions) = &self.sessions {
            sessions.revoke_all();
        }
    }

    /// Authenticate an application-owned management route. Attach the returned authorization
    /// to its response using `AdminAuthorization::apply`, including after a use-case error.
    /// A rejection is already a complete HTTP response.
    pub fn authorize(
        &self,
        method: &Method,
        headers: &HeaderMap,
    ) -> Result<AdminAuthorization, Box<Response<Bytes>>> {
        let sessions = self
            .sessions
            .as_ref()
            .ok_or_else(|| Box::new(not_found()))?;
        sessions
            .authorize(method, headers)
            .map_err(|failure| Box::new(failure.response()))
    }
}

#[must_use = "apply the session renewal and no-store headers to the management response"]
pub struct AdminAuthorization(Option<sessions::Renewal>);

impl AdminAuthorization {
    pub fn apply(self, response: &mut Response<Bytes>) {
        let headers = response.headers_mut();
        headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
        headers.insert(CONNECTION, HeaderValue::from_static("close"));
        if let Some(renewal) = self.0 {
            headers.insert(SET_COOKIE, renewal.header());
        }
    }
}

#[derive(Clone, Copy)]
enum Failure {
    InvalidCommand,
    JsonTooDeep,
    Credential,
    Host,
    Origin,
    Csrf,
    Mixed,
    Unavailable,
}

impl Failure {
    fn response(self) -> Response<Bytes> {
        use StatusCode as Status;
        let (status, code) = match self {
            Self::InvalidCommand => (Status::BAD_REQUEST, "invalid_command"),
            Self::JsonTooDeep => (Status::BAD_REQUEST, "json_too_deep"),
            Self::Credential => (Status::UNAUTHORIZED, "invalid_admin_credential"),
            Self::Host => (Status::FORBIDDEN, "invalid_management_host"),
            Self::Origin => (Status::FORBIDDEN, "invalid_management_origin"),
            Self::Csrf => (Status::FORBIDDEN, "invalid_csrf"),
            Self::Mixed => (Status::FORBIDDEN, "mixed_browser_credentials"),
            Self::Unavailable => (Status::SERVICE_UNAVAILABLE, "management_unavailable"),
        };
        json_response(
            status,
            "application/json",
            &json!({
                "error": {
                    "code": code,
                    "message": "Management request failed.",
                    "request_id": request_id(),
                }
            }),
        )
    }
}

fn request_id() -> String {
    static FALLBACK: AtomicU64 = AtomicU64::new(0);
    let mut bytes = [0; 16];
    if getrandom::fill(&mut bytes).is_ok() {
        Builder::from_random_bytes(bytes)
            .into_uuid()
            .to_string()
            .to_uppercase()
    } else {
        // Keep error reporting available if the OS random source itself failed.
        format!("local-{}", FALLBACK.fetch_add(1, Ordering::Relaxed))
    }
}

pub fn not_found() -> Response<Bytes> {
    json_response(
        StatusCode::NOT_FOUND,
        "application/json",
        &json!({
            "error": {"code": "request_failed", "message": "Request failed."}
        }),
    )
}

pub fn request_too_large() -> Response<Bytes> {
    json_response(
        StatusCode::PAYLOAD_TOO_LARGE,
        "application/json; charset=utf-8",
        &json!({
            "error": {"code": "request_too_large"}
        }),
    )
}

fn json_response(
    status: StatusCode,
    content_type: &'static str,
    payload: &impl Serialize,
) -> Response<Bytes> {
    response(
        status,
        content_type,
        "no-store",
        serde_json::to_vec(payload)
            .expect("serialize management response")
            .into(),
    )
}

fn response(
    status: StatusCode,
    content_type: &'static str,
    cache_control: &'static str,
    body: Bytes,
) -> Response<Bytes> {
    let mut response = Response::new(body);
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static(cache_control));
    headers.insert(CONNECTION, HeaderValue::from_static("close"));
    response
}
