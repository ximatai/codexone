use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use bytes::Bytes;
use codexone_config::ResponsesConfiguration;
use codexone_execution::{AccountIdentity, ExecutionService};
use codexone_http_upstream::{Error as UpstreamError, ExchangeOptions, HttpUpstream, RequestBody};
use codexone_responses::{JsonValue, ProtocolError, http_provider_failure};
use http::{HeaderMap, HeaderValue, Method, Request, Response, StatusCode, Uri, header};
use hyper::body::Incoming;
use tokio::time::{Instant, timeout_at};

use crate::{
    headers::{self, hop_by_hop},
    listener::{DataBodies, ReadError},
    managed::Pool,
    reply::{self, Reply},
    response::ResponseError,
};

const MAX_REQUEST: usize = 8 * 1024 * 1024;
const MAX_RESPONSE: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy)]
pub struct Route(&'static str);

impl Route {
    pub fn recognize(method: &Method, path: &str) -> Option<Self> {
        let path = match (method, path) {
            (&Method::POST, "/backend-api/codex/alpha/search") => "/backend-api/codex/alpha/search",
            (&Method::POST, "/backend-api/codex/memories/trace_summarize") => {
                "/backend-api/codex/memories/trace_summarize"
            }
            (&Method::POST, "/backend-api/codex/realtime/calls") => {
                "/backend-api/codex/realtime/calls"
            }
            (&Method::POST, "/backend-api/codex/safety/arc") => "/backend-api/codex/safety/arc",
            (&Method::GET | &Method::POST, "/backend-api/codex/thread/goal/get") => {
                "/backend-api/codex/thread/goal/get"
            }
            (&Method::POST, "/backend-api/codex/thread/goal/set") => {
                "/backend-api/codex/thread/goal/set"
            }
            (&Method::POST, "/backend-api/codex/thread/goal/clear") => {
                "/backend-api/codex/thread/goal/clear"
            }
            (&Method::GET, "/backend-api/codex/agent-identities/jwks") => {
                "/backend-api/codex/agent-identities/jwks"
            }
            (&Method::GET, "/backend-api/wham/agent-identities/jwks") => {
                "/backend-api/wham/agent-identities/jwks"
            }
            (&Method::POST, "/backend-api/codex/analytics-events/events") => {
                "/backend-api/codex/analytics-events/events"
            }
            _ => return None,
        };
        Some(Self(path))
    }

    fn duration(self) -> Duration {
        Duration::from_secs(if self.0.ends_with("/trace_summarize") {
            300
        } else {
            60
        })
    }
}

type RouteCooldowns = HashMap<(AccountIdentity, &'static str), Instant>;

pub struct Control {
    base: Uri,
    slots: Arc<Mutex<HashMap<String, usize>>>,
    cooldowns: Arc<Mutex<RouteCooldowns>>,
}

impl Control {
    pub fn new(base: Uri) -> Self {
        Self {
            base,
            slots: Default::default(),
            cooldowns: Default::default(),
        }
    }

    fn acquire(&self, key: &str) -> Option<Slot> {
        let mut slots = self.slots.lock().unwrap();
        if slots.values().sum::<usize>() >= 8 || slots.get(key).copied().unwrap_or(0) >= 4 {
            return None;
        }
        *slots.entry(key.to_owned()).or_default() += 1;
        Some(Slot {
            key: key.to_owned(),
            slots: self.slots.clone(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn handle(
        &self,
        route: Route,
        request: Request<Incoming>,
        execution: &ExecutionService,
        bodies: &DataBodies,
        upstream: &HttpUpstream,
        config: &ResponsesConfiguration,
        token: Option<&HeaderValue>,
        pool: Option<&Pool>,
        request_id: &str,
    ) -> Reply {
        let key = match execution
            .authenticate(&headers::values(request.headers(), "authorization"))
            .await
        {
            Ok(key) => key,
            Err(error) => return ResponseError::from(error).reply(request_id, HeaderMap::new()),
        };
        let Some(slot) = self.acquire(key.id()) else {
            return reply::error(
                ProtocolError::new(429, "control_capacity_exhausted"),
                None,
                request_id,
                HeaderMap::from_iter([(header::RETRY_AFTER, HeaderValue::from_static("1"))]),
            );
        };
        let began = Instant::now();
        let result = async {
            if request.headers().contains_key(header::CONTENT_ENCODING) {
                return Err(ProtocolError::new(415, "unsupported_content_type").into());
            }
            let (parts, incoming) = request.into_parts();
            let (body, _permit) = bodies
                .read_control(incoming, key.id(), request_id, MAX_REQUEST)
                .await
                .map_err(|error| match error {
                    ReadError::TooLarge => ProtocolError::new(413, "request_too_large").into(),
                    ReadError::Timeout => ProtocolError::new(408, "request_body_timeout").into(),
                    ReadError::Interrupted => ProtocolError::new(400, "invalid_json").into(),
                    ReadError::Capacity => ResponseError::body_capacity(),
                })?;
            let local = route.0.ends_with("/analytics-events/events");
            if local || pool.is_none() {
                // Authentication before buffering bounds unauthenticated work. Recheck
                // after a slow upload on routes that do not select a subscription account.
                let current = execution
                    .authenticate(&headers::values(&parts.headers, "authorization"))
                    .await?;
                if current.id() != key.id() {
                    return Err(codexone_execution::ExecutionError::Unauthorized.into());
                }
            }
            if local {
                return Ok(reply::json(
                    StatusCode::ACCEPTED,
                    Bytes::from_static(b"{}"),
                    HeaderMap::new(),
                    request_id,
                    None,
                ));
            }
            let deadline = Instant::now() + route.duration();
            let mut outbound_headers = headers::client(
                &parts.headers,
                &JsonValue::Null,
                &config.client_fingerprint,
                &config.models,
            )?;
            for name in [header::CONTENT_TYPE, header::ACCEPT] {
                if !hop_by_hop(&parts.headers, name.as_str()) {
                    for value in parts.headers.get_all(&name) {
                        outbound_headers.append(name.clone(), value.clone());
                    }
                }
            }
            let cooldowns = self.cooldowns.clone();
            let selected = if let Some(pool) = pool {
                let picked = timeout_at(
                    deadline,
                    pool.select_control(execution, &key, &outbound_headers, move |identity| {
                        cooldowns
                            .lock()
                            .unwrap()
                            .get(&(identity.clone(), route.0))
                            .map_or(Duration::ZERO, |until| {
                                until.saturating_duration_since(Instant::now())
                            })
                    }),
                )
                .await
                .map_err(|_| ProtocolError::new(504, "execution_deadline_exceeded"))??;
                outbound_headers.extend(picked.1);
                Some(picked.0)
            } else {
                if let Some(token) = token {
                    outbound_headers.insert(header::AUTHORIZATION, token.clone());
                }
                None
            };
            let mut target = self.base.clone().into_parts();
            let path = match parts.uri.query() {
                Some(query) => format!("{}?{query}", route.0),
                None => route.0.to_owned(),
            };
            target.path_and_query = Some(
                path.parse()
                    .map_err(|_| ProtocolError::new(400, "invalid_request"))?,
            );
            let target = Uri::from_parts(target)
                .map_err(|_| ProtocolError::new(503, "execution_indeterminate"))?;
            let mut outbound = Request::new(RequestBody::bytes(body));
            *outbound.method_mut() = parts.method;
            *outbound.uri_mut() = target;
            *outbound.headers_mut() = outbound_headers;
            let mut options = ExchangeOptions::new(deadline, route.duration(), MAX_RESPONSE);
            if let Some(owner) = &selected {
                options.cancellation = owner.stop_token().clone();
            }
            let received = upstream
                .send_buffered(outbound, options, |_, _| true)
                .await
                .map_err(control_transport)?;
            let succeeded = (200..400).contains(&received.status.as_u16());
            if !succeeded {
                let raw = match received.body {
                    Err(error @ (UpstreamError::DeadlineExceeded | UpstreamError::Cancelled)) => {
                        return Err(control_transport(error));
                    }
                    body => body.ok().flatten(),
                };
                let failure = http_provider_failure(
                    received.status.as_u16(),
                    raw.as_deref(),
                    &headers::values(&received.headers, "retry-after"),
                    &headers::values(&received.headers, "connection"),
                    false,
                );
                if let Some(owner) = &selected {
                    match failure.protocol.code {
                        "upstream_authentication_rejected" | "upstream_rate_limited" => {
                            timeout_at(
                                deadline,
                                execution.record_control_failure(
                                    owner,
                                    failure.protocol.code == "upstream_authentication_rejected",
                                    failure.account_cooldown(crate::unix_time()),
                                ),
                            )
                            .await
                            .map_err(|_| {
                                ProtocolError::new(504, "execution_deadline_exceeded")
                            })??;
                        }
                        "upstream_unavailable" => {
                            self.cool(route, owner.identity(), failure.cooldown_seconds)
                        }
                        _ => {}
                    }
                }
                return Err(Box::new(failure).into());
            }
            let body = received
                .body
                .map_err(control_transport)?
                .unwrap_or_default();
            let mut forwarded = headers::provider(&received.headers, false);
            for (name, value) in &received.headers {
                if matches!(
                    name.as_str(),
                    "content-type"
                        | "content-encoding"
                        | "vary"
                        | "cache-control"
                        | "etag"
                        | "last-modified"
                        | "retry-after"
                ) && !hop_by_hop(&received.headers, name.as_str())
                {
                    forwarded.append(name.clone(), value.clone());
                }
            }
            if let (Some(pool), Some(owner)) = (pool, &selected) {
                pool.observe_turn_state(key.id(), owner.identity(), &received.headers);
            }
            let mut response = Response::new(Bytes::from_owner(ControlBody {
                bytes: body,
                _slot: slot,
            }));
            *response.status_mut() = received.status;
            *response.headers_mut() = forwarded;
            response.headers_mut().insert(
                "x-request-id",
                request_id.parse().expect("request UUID header"),
            );
            Ok(reply::from_bytes(response))
        }
        .await;
        let response =
            result.unwrap_or_else(|error: ResponseError| error.reply(request_id, HeaderMap::new()));
        log(route, key.id(), response.status(), began);
        response
    }

    fn cool(&self, route: Route, identity: &AccountIdentity, hint: Option<i64>) {
        let now = Instant::now();
        let until = now + Duration::from_secs(hint.unwrap_or(15).clamp(1, 3600) as u64);
        let mut cooldowns = self.cooldowns.lock().unwrap();
        cooldowns.retain(|_, until| *until > now);
        if cooldowns.len() >= 1024
            && !cooldowns.contains_key(&(identity.clone(), route.0))
            && let Some(oldest) = cooldowns
                .iter()
                .min_by_key(|(_, until)| *until)
                .map(|(key, _)| key.clone())
        {
            cooldowns.remove(&oldest);
        }
        let entry = cooldowns
            .entry((identity.clone(), route.0))
            .or_insert(until);
        *entry = (*entry).max(until);
    }
}

struct ControlBody {
    bytes: Bytes,
    _slot: Slot,
}

impl AsRef<[u8]> for ControlBody {
    fn as_ref(&self) -> &[u8] {
        &self.bytes
    }
}

struct Slot {
    key: String,
    slots: Arc<Mutex<HashMap<String, usize>>>,
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut slots = self.slots.lock().unwrap();
        if let Some(count) = slots.get_mut(&self.key) {
            *count -= 1;
            if *count == 0 {
                slots.remove(&self.key);
            }
        }
    }
}

fn control_transport(error: UpstreamError) -> ResponseError {
    match error {
        UpstreamError::FirstResponseTimeout | UpstreamError::DeadlineExceeded => {
            ProtocolError::new(504, "execution_deadline_exceeded").into()
        }
        UpstreamError::Cancelled => codexone_execution::ExecutionError::AccountForceStopped.into(),
        _ => error.into(),
    }
}

fn log(route: Route, key: &str, status: StatusCode, began: Instant) {
    static GATE: Mutex<Option<(Instant, u8)>> = Mutex::new(None);
    let now = Instant::now();
    let mut gate = GATE.lock().unwrap();
    let (window, count) = gate.get_or_insert((now, 0));
    if now.duration_since(*window) >= Duration::from_secs(60) {
        (*window, *count) = (now, 0);
    }
    if *count >= 16 {
        return;
    }
    *count += 1;
    drop(gate);
    let elapsed = now.duration_since(began).as_millis();
    if route.0.ends_with("/realtime/calls") {
        eprintln!(
            "Control request ended status={} elapsed_ms={elapsed}",
            status.as_u16()
        );
    } else {
        let path = route.0.trim_start_matches("/backend-api/");
        eprintln!(
            "Control request ended path_category={path} key_id={key} status={} elapsed_ms={elapsed}",
            status.as_u16()
        );
    }
}
