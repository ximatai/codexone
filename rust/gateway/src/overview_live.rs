use std::{
    collections::BTreeMap,
    future::{pending, poll_fn},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use base64::{Engine, engine::general_purpose::STANDARD};
use bytes::Bytes;
use codexone_admin::{AdminRouter, OverviewSession};
use codexone_usage::{Error, OverviewSection, OverviewSource, OverviewStamp, OverviewState};
use futures_util::{Sink, SinkExt, StreamExt};
use http::{Method, Request, Response, StatusCode, header};
use hyper::{body::Incoming, upgrade::OnUpgrade};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tokio::{
    sync::{Notify, OwnedSemaphorePermit, Semaphore, watch},
    time::{self, Instant, timeout},
};
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{
        Message,
        handshake::derive_accept_key,
        protocol::{CloseFrame, Role, WebSocketConfig, frame::coding::CloseCode},
    },
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{gateway::Application, management_usage::unix_now};

pub const PATH: &str = "/api/overview/live";
const MAX_VIEWERS: usize = 8;
const FRAME_BYTES: usize = 1024 * 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const PING_PERIOD: Duration = Duration::from_secs(15);
const PONG_TIMEOUT: Duration = Duration::from_secs(10);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
const EVENT_DELAY: Duration = Duration::from_millis(100);

type Sections = BTreeMap<OverviewSource, OverviewSection>;
type Stamps = BTreeMap<OverviewSource, OverviewStamp>;

pub struct OverviewHub {
    slots: Arc<Semaphore>,
    transitions: Notify,
    latest: watch::Sender<Option<Arc<Sections>>>,
    epoch: Uuid,
}

impl OverviewHub {
    pub fn new() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(MAX_VIEWERS)),
            transitions: Notify::new(),
            latest: watch::channel(None).0,
            epoch: Uuid::new_v4(),
        }
    }

    fn has_viewers(&self) -> bool {
        self.slots.available_permits() < MAX_VIEWERS
    }

    fn join(self: &Arc<Self>) -> Option<Viewer> {
        let permit = self.slots.clone().try_acquire_owned().ok()?;
        self.transitions.notify_one();
        Some(Viewer {
            hub: self.clone(),
            permit: Some(permit),
        })
    }

    async fn wait_for_viewers(&self, present: bool) {
        while self.has_viewers() != present {
            self.transitions.notified().await;
        }
    }

    pub async fn run(&self, app: Arc<Application>, stopping: CancellationToken) {
        let Some(usage) = app.usage.as_ref() else {
            return;
        };
        let mut state = OverviewState::new(unix_now());
        loop {
            tokio::select! {
                _ = stopping.cancelled() => return,
                _ = self.wait_for_viewers(true) => {}
            }
            let mut revision = app
                .execution
                .as_ref()
                .expect("usage writer")
                .activity_revision();
            let mut data_clients = app.data_clients.as_ref().map(|clients| clients.revision());
            let sample = async {
                let now = Instant::now();
                let mut storage_due = now;
                let mut aggregate_due = now;
                let mut reports_due = now;
                let mut last_aggregate = None;
                let mut activity_due = None;
                let mut dirty = false;
                loop {
                    let now = Instant::now();
                    let at = unix_now();
                    let sample_aggregate = now >= aggregate_due
                        || (dirty
                            && last_aggregate
                                .is_some_and(|at: Instant| at.elapsed() >= Duration::from_secs(2)));
                    let sample_storage = now >= storage_due;
                    let sample_reports = now >= reports_due;
                    let sample_activity = activity_due.is_some_and(|due| due <= now);
                    let storage = if sample_storage || sample_aggregate || sample_reports {
                        Some(usage.storage(at).await)
                    } else {
                        None
                    };
                    let mut other = BTreeMap::new();
                    if sample_aggregate {
                        let sampled = usage
                            .usage
                            .sample_overview(
                                at,
                                Arc::new(
                                    usage.activity_context(storage.clone().unwrap_or_default()),
                                ),
                            )
                            .await;
                        if state.update_usage(at, sampled).is_err() {
                            self.latest.send_replace(None);
                            return;
                        }
                        other.insert(OverviewSource::System, app.overview_system().await);
                        last_aggregate = Some(now);
                        aggregate_due = now + Duration::from_secs(5);
                        activity_due = None;
                        dirty = false;
                    } else if sample_activity {
                        let context = Arc::new(usage.activity_context(Value::Null));
                        other.insert(
                            OverviewSource::InFlight,
                            usage.usage.sample_activity(at, context).await,
                        );
                        activity_due = None;
                    }
                    if sample_reports {
                        let accounts = match app.managed.as_ref() {
                            Some(managed) => managed.overview_accounts().await,
                            None => Err(Error::Unavailable),
                        };
                        other.insert(OverviewSource::Accounts, accounts);
                        let context =
                            Arc::new(usage.attention_context(storage.clone().unwrap_or_default()));
                        other.insert(
                            OverviewSource::Attention,
                            usage.usage.attention(at, context).await,
                        );
                        reports_due = now + Duration::from_secs(15);
                    }
                    if sample_storage {
                        let storage = usage.storage_with_resources(storage.unwrap_or_default(), at);
                        other.insert(OverviewSource::Storage, Ok(storage));
                        storage_due = now + Duration::from_secs(2);
                    }
                    if !other.is_empty() && state.update(at, other).is_err() {
                        self.latest.send_replace(None);
                        return;
                    }
                    self.latest.send_if_modified(|latest| {
                        if latest.as_deref() == Some(state.snapshot()) {
                            false
                        } else {
                            *latest = Some(Arc::new(state.snapshot().clone()));
                            true
                        }
                    });

                    let mut next = storage_due.min(aggregate_due).min(reports_due);
                    if let Some(due) = activity_due {
                        next = next.min(due);
                    }
                    if dirty && let Some(last) = last_aggregate {
                        next = next.min(last + Duration::from_secs(2));
                    }
                    tokio::select! {
                        _ = time::sleep_until(next) => {}
                        changed = changed_clients(&mut data_clients), if activity_due.is_none() => {
                            if changed.is_err() { return; }
                            activity_due = Some(Instant::now() + EVENT_DELAY);
                        }
                        changed = revision.changed(), if activity_due.is_none() => {
                            if changed.is_err() { return; }
                            activity_due = Some(Instant::now() + EVENT_DELAY);
                            dirty = true;
                        }
                    }
                }
            };
            tokio::select! {
                _ = stopping.cancelled() => return,
                _ = self.wait_for_viewers(false) => {}
                _ = sample => {
                    // Failed cache publication invalidates connected viewers. Wait
                    // for them to release their slots before restarting the sampler.
                    tokio::select! {
                        _ = stopping.cancelled() => return,
                        _ = self.wait_for_viewers(false) => {}
                    }
                }
            }
            self.latest.send_replace(None);
            tokio::select! {
                _ = stopping.cancelled() => return,
                _ = usage.wait_idle() => {}
            }
        }
    }
}

async fn changed_clients(
    revision: &mut Option<watch::Receiver<u64>>,
) -> Result<(), watch::error::RecvError> {
    match revision {
        Some(revision) => revision.changed().await,
        None => pending().await,
    }
}

struct Viewer {
    hub: Arc<OverviewHub>,
    permit: Option<OwnedSemaphorePermit>,
}

impl Drop for Viewer {
    fn drop(&mut self) {
        drop(self.permit.take());
        self.hub.transitions.notify_one();
    }
}

pub struct PendingUpgrade {
    upgrade: OnUpgrade,
    session: OverviewSession,
    viewer: Viewer,
}

fn reject(status: StatusCode) -> Response<Bytes> {
    Response::builder()
        .status(status)
        .header(header::CONNECTION, "close")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Bytes::new())
        .expect("static upgrade rejection")
}

pub fn upgrade(
    request: &mut Request<Incoming>,
    router: &AdminRouter,
    hub: &Arc<OverviewHub>,
) -> Result<(Response<Bytes>, PendingUpgrade), Box<Response<Bytes>>> {
    let headers = request.headers();
    let bad = || Box::new(reject(StatusCode::BAD_REQUEST));
    let unique = |name: &str| {
        let mut values = headers.get_all(name).iter();
        let value = values.next()?.to_str().ok()?;
        values.next().is_none().then_some(value)
    };
    let Some(key) = unique("sec-websocket-key") else {
        return Err(bad());
    };
    if request.method() != Method::GET
        || request.uri().query().is_some()
        || request.version() != http::Version::HTTP_11
        || headers.contains_key(header::TRANSFER_ENCODING)
        || (headers.contains_key(header::CONTENT_LENGTH) && unique("content-length") != Some("0"))
        || headers.contains_key("sec-websocket-protocol")
        || !unique("upgrade").is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
        || !unique("connection").is_some_and(|value| {
            value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
        })
        || unique("sec-websocket-version") != Some("13")
        || !STANDARD
            .decode(key)
            .is_ok_and(|decoded| decoded.len() == 16)
    {
        return Err(bad());
    }
    let accept = derive_accept_key(key.as_bytes());
    let session = router.overview_session(headers)?;
    let viewer = hub
        .join()
        .ok_or_else(|| Box::new(codexone_admin::overview_capacity()))?;
    let response = Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header(header::UPGRADE, "websocket")
        .header(header::CONNECTION, "upgrade")
        .header("sec-websocket-accept", accept)
        .header(header::CACHE_CONTROL, "no-store")
        .body(Bytes::new())
        .expect("static upgrade headers");
    let upgrade = hyper::upgrade::on(request);
    Ok((
        response,
        PendingUpgrade {
            upgrade,
            session,
            viewer,
        },
    ))
}

impl PendingUpgrade {
    pub async fn run(
        self,
        draining: CancellationToken,
        upgraded: Arc<AtomicBool>,
        deadline: Instant,
    ) {
        let Self {
            upgrade,
            session,
            viewer,
        } = self;
        let stream = tokio::select! {
            biased;
            result = time::timeout_at(deadline, upgrade) => match result {
                Ok(Ok(stream)) => stream,
                _ => return,
            },
            _ = draining.cancelled() => return,
            _ = session.revoked() => return,
        };
        upgraded.store(true, Ordering::Relaxed);
        let config = WebSocketConfig::default()
            .read_buffer_size(4096)
            .write_buffer_size(0)
            .max_write_buffer_size(FRAME_BYTES + 16)
            .max_message_size(Some(125))
            .max_frame_size(Some(125));
        let mut socket =
            WebSocketStream::from_raw_socket(TokioIo::new(stream), Role::Server, Some(config))
                .await;
        let mut samples = viewer.hub.latest.subscribe();
        if samples.borrow().is_some() {
            samples.mark_changed();
        }
        let epoch = viewer.hub.epoch;
        let mut previous = None;
        let mut sequence = 1u64;
        let mut ping = time::interval_at(Instant::now() + PING_PERIOD, PING_PERIOD);
        ping.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
        let mut awaiting_pong: Option<(Instant, Bytes)> = None;
        let close = loop {
            if draining.is_cancelled() {
                break CloseCode::Away;
            }
            if !session.valid() {
                break CloseCode::Policy;
            }
            let pong_due = awaiting_pong.as_ref().map(|(deadline, _)| *deadline);
            let write_deadline = || {
                let deadline = Instant::now() + WRITE_TIMEOUT;
                pong_due.map_or(deadline, |due| due.min(deadline))
            };
            tokio::select! {
                biased;
                _ = draining.cancelled() => break CloseCode::Away,
                _ = session.revoked() => break CloseCode::Policy,
                _ = pong_deadline(pong_due) => break CloseCode::Again,
                _ = ping.tick() => {
                    let payload = Bytes::copy_from_slice(&sequence.to_be_bytes());
                    if let Err(code) = send(&mut socket, &session, &draining, Message::Ping(payload.clone()), write_deadline(), true).await {
                        break code;
                    }
                    awaiting_pong = Some((Instant::now() + PONG_TIMEOUT, payload));
                }
                changed = samples.changed() => {
                    if changed.is_err() { break CloseCode::Away; }
                    let latest = samples.borrow_and_update().clone();
                    let Some(latest) = latest else { break CloseCode::Again; };
                    let frame = encode(epoch, sequence, &latest, previous.as_ref());
                    let Ok(Some(frame)) = frame else {
                        if frame.is_ok() { continue; }
                        break CloseCode::Again;
                    };
                    let stamps = latest.iter().map(|(source, section)| (*source, section.stamp())).collect();
                    drop(latest);
                    if let Err(code) = send(&mut socket, &session, &draining, Message::Text(frame.into()), write_deadline(), false).await {
                        break code;
                    }
                    previous = Some(stamps);
                    sequence += 1;
                }
                message = socket.next() => match message {
                    Some(Ok(Message::Pong(payload))) if awaiting_pong.as_ref().is_some_and(|(_, expected)| payload == *expected) => {
                        awaiting_pong = None;
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Ping(_))) => {
                        tokio::select! {
                            biased;
                            _ = draining.cancelled() => break CloseCode::Away,
                            _ = session.revoked() => break CloseCode::Policy,
                            sent = time::timeout_at(write_deadline(), socket.flush()) => {
                                if !matches!(sent, Ok(Ok(()))) { break CloseCode::Again; }
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) => {
                        let _ = timeout(CLOSE_TIMEOUT, socket.flush()).await;
                        return;
                    }
                    _ => return,
                },
            }
        };
        let _ = timeout(CLOSE_TIMEOUT, async {
            socket
                .send(Message::Close(Some(CloseFrame {
                    code: close,
                    reason: "".into(),
                })))
                .await?;
            while let Some(message) = socket.next().await {
                if !matches!(message, Ok(Message::Ping(_) | Message::Pong(_))) {
                    break;
                }
            }
            Ok::<(), tokio_tungstenite::tungstenite::Error>(())
        })
        .await;
    }
}

async fn send<S>(
    socket: &mut WebSocketStream<S>,
    session: &OverviewSession,
    draining: &CancellationToken,
    message: Message,
    deadline: Instant,
    renew: bool,
) -> Result<(), CloseCode>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let writing = async {
        poll_fn(|cx| Pin::new(&mut *socket).poll_ready(cx))
            .await
            .map_err(|_| CloseCode::Again)?;
        session
            .with_valid(renew, || Pin::new(&mut *socket).start_send(message))
            .ok_or(CloseCode::Policy)?
            .map_err(|_| CloseCode::Again)?;
        socket.flush().await.map_err(|_| CloseCode::Again)
    };
    tokio::select! {
        biased;
        _ = draining.cancelled() => Err(CloseCode::Away),
        _ = session.revoked() => Err(CloseCode::Policy),
        result = time::timeout_at(deadline, writing) => result.unwrap_or(Err(CloseCode::Again)),
    }
}

async fn pong_deadline(waiting: Option<Instant>) {
    match waiting {
        Some(deadline) => time::sleep_until(deadline).await,
        None => pending().await,
    }
}

fn encode(
    epoch: Uuid,
    sequence: u64,
    latest: &Sections,
    previous: Option<&Stamps>,
) -> Result<Option<String>, Error> {
    let epoch = epoch.to_string();
    let value = if let Some(previous) = previous {
        let mut changed = BTreeMap::new();
        for (source, section) in latest {
            if let Some(update) = section.update_document(previous[source])? {
                changed.insert(source, update);
            }
        }
        if changed.is_empty() {
            return Ok(None);
        }
        json!({"protocol": 1, "epoch": epoch, "sequence": sequence, "kind": "update", "sections": changed})
    } else {
        json!({"protocol": 1, "epoch": epoch, "sequence": sequence, "kind": "snapshot", "sections": latest})
    };
    let frame = serde_json::to_string(&value).map_err(|_| Error::Unavailable)?;
    if frame.len() > FRAME_BYTES {
        return Err(Error::Capacity);
    }
    Ok(Some(frame))
}
