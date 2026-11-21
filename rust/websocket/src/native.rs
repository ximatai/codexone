use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::pending,
    sync::{Arc, Mutex, Weak},
    time::Duration,
};

use codexone_responses::{
    JsonValue, MAX_EVENT_BYTES, ProtocolError, ProviderFailure, sanitize_client_output,
};
use futures_util::{FutureExt, StreamExt, future::BoxFuture, stream::FuturesUnordered};
use tokio::time::{Instant, sleep_until, timeout_at};
use tokio_tungstenite::tungstenite::{Utf8Bytes, protocol::frame::coding::CloseCode};

use crate::{
    CancellationToken, ConnectFailure, DownstreamSocket, ExecutionBudget, QUEUE_TIMEOUT, Socket,
    SocketEnd, WS_ROUTING_BYTES,
    ingress::{IngressLease, IngressMessage},
    peer::{DOWNSTREAM_QUEUE_BYTES, Packet, Peer, Read},
    protocol::{
        DEADLINE, INDETERMINATE, TOO_LARGE, UNSUPPORTED_CONTROL, control, decode_client_message,
        websocket_error, websocket_lane, with_lane,
    },
    turns::{Interrupt, Route, Turn, Turns, decode_event, provider_failure},
};

const MAX_LANES: usize = 32;
const MAX_ACTIVE: usize = 16;
const MAX_QUEUE: usize = 64;
const MAX_LANE_QUEUE: usize = 4;
const FIRST_CREATE: Duration = Duration::from_secs(10);
const CONNECTION_IDLE: Duration = Duration::from_secs(120);
const CONNECTION_LIFETIME: Duration = Duration::from_secs(3600);
const DISCONNECT_DRAIN: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Default)]
pub struct NativeOptions {
    pub budget: ExecutionBudget,
}

pub struct PreparedCreate<T> {
    pub admission: T,
    pub frame: Utf8Bytes,
    pub warmup: bool,
}

pub struct Admitted<T, I> {
    pub attempt: T,
    pub identity: I,
}

pub enum NativeEvidence<'a> {
    Event(&'a JsonValue),
    PossibleProcessing,
}

#[derive(Debug)]
pub enum NativeFinish {
    Terminal {
        client_cancelled: bool,
    },
    Provider {
        failure: Box<ProviderFailure>,
        client_cancelled: bool,
    },
    BeforeDispatch {
        protocol: ProtocolError,
        provider: Option<Box<ProviderFailure>>,
    },
    UnprocessedSizeRefusal,
    Indeterminate {
        protocol: ProtocolError,
        socket: Option<SocketEnd>,
        client_cancelled: bool,
    },
}

/// Adapter for an already locally authenticated WebSocket session. Admission must be
/// cancellation-safe, including any durable work completed before returning its handle.
pub trait NativeApplication: Send + Sync + 'static {
    type Input: Send;
    type Attempt: Send + Sync + 'static;
    type Identity: Clone + Eq + Send + Sync;

    fn prepare(
        &self,
        lane: &str,
        document: JsonValue,
    ) -> Result<PreparedCreate<Self::Input>, ProtocolError>;

    fn admit(
        &self,
        input: Self::Input,
        identity: Option<Self::Identity>,
        deadline: Instant,
    ) -> impl Future<Output = Result<Admitted<Self::Attempt, Self::Identity>, ProtocolError>> + Send;

    fn connect(
        &self,
        identity: &Self::Identity,
        deadline: Instant,
    ) -> impl Future<Output = Result<Socket, ConnectFailure>> + Send;

    /// Synchronously record or hand off trusted evidence before downstream submission.
    /// This runs on the provider reader and may overlap another lane's async binding.
    fn evidence(&self, attempt: &Self::Attempt, evidence: NativeEvidence<'_>);

    /// Apply binding barriers and any application validation before forwarding a correlated event.
    fn before_output(
        &self,
        attempt: &Self::Attempt,
        document: &JsonValue,
    ) -> impl Future<Output = Result<(), ProtocolError>> + Send;

    /// Transfer responsibility for durable finalization to the application exactly once.
    fn finish(&self, attempt: Self::Attempt, result: NativeFinish);
}

#[derive(Debug)]
pub enum NativeEnd {
    Downstream(SocketEnd),
    Upstream(SocketEnd),
    Protocol(ProtocolError),
    TurnTimeout {
        lane: String,
        protocol: ProtocolError,
    },
    Cancelled,
    Idle,
    Lifetime,
}

struct ReaderState<A: NativeApplication> {
    turns: Turns,
    attempts: HashMap<String, Weak<A::Attempt>>,
}

type SharedReader<A> = Arc<Mutex<ReaderState<A>>>;
type UpstreamPacket = Result<RoutedEvent, ProtocolError>;

struct RoutedEvent {
    document: JsonValue,
    route: Route,
}

impl<A: NativeApplication> ReaderState<A> {
    fn new() -> Self {
        Self {
            turns: Turns::new(),
            attempts: HashMap::new(),
        }
    }

    fn inspect(&mut self, app: &A, document: JsonValue, bytes: usize) -> Read<UpstreamPacket> {
        let route = self.turns.observe(&document, bytes);
        for (lane, turn) in &mut self.turns.active {
            if std::mem::take(&mut turn.unattributed)
                && let Some(attempt) = self.attempts.get(lane).and_then(Weak::upgrade)
            {
                app.evidence(&attempt, NativeEvidence::PossibleProcessing);
            }
        }
        match route {
            Ok(Route::Ignore) => Read::Ignore,
            Ok(route) => {
                if let Route::Turn { lane, .. } = &route
                    && let Some(attempt) = self.attempts.get(lane).and_then(Weak::upgrade)
                {
                    app.evidence(&attempt, NativeEvidence::Event(&document));
                }
                Read::Deliver(Ok(RoutedEvent { document, route }))
            }
            Err(error) => Read::Stop(Err(error)),
        }
    }
}

struct OwnedAttempt<A: NativeApplication> {
    app: Arc<A>,
    attempt: Option<Arc<A::Attempt>>,
    reader: Option<(SharedReader<A>, String)>,
    _lease: Box<dyn IngressLease>,
    cancelled: bool,
}

impl<A: NativeApplication> OwnedAttempt<A> {
    fn register(&mut self, reader: SharedReader<A>, lane: String, turn: Turn) {
        let handle = self.attempt.as_ref().expect("attempt owner");
        {
            let mut state = reader.lock().expect("provider reader state");
            state.attempts.insert(lane.clone(), Arc::downgrade(handle));
            state.turns.active.insert(lane.clone(), turn);
        }
        self.reader = Some((reader, lane));
    }

    fn take(&mut self) -> Option<A::Attempt> {
        if let Some((reader, lane)) = self.reader.take() {
            // The reader only upgrades the weak handle while holding this lock. Deregister
            // before handing the attempt to the finalizer, including when the owner is dropped.
            let mut state = reader.lock().expect("provider reader state");
            state.attempts.remove(&lane);
            state.turns.remove(&lane, true);
        }
        self.attempt
            .take()
            .map(|attempt| Arc::into_inner(attempt).expect("attempt owner"))
    }

    fn finish(mut self, result: NativeFinish) {
        let attempt = self.take().expect("attempt owner");
        self.app.finish(attempt, result);
    }

    fn attempt(&self) -> &A::Attempt {
        self.attempt.as_deref().expect("attempt owner")
    }
}

impl<A: NativeApplication> Drop for OwnedAttempt<A> {
    fn drop(&mut self) {
        let dispatched = self.reader.is_some();
        if let Some(attempt) = self.take() {
            let result = if dispatched {
                NativeFinish::Indeterminate {
                    protocol: INDETERMINATE,
                    socket: Some(SocketEnd::Cancelled),
                    client_cancelled: self.cancelled,
                }
            } else {
                NativeFinish::BeforeDispatch {
                    protocol: INDETERMINATE,
                    provider: None,
                }
            };
            self.app.finish(attempt, result);
        }
    }
}

struct Command {
    packet: Packet<IngressMessage>,
    lane: String,
}

struct Admission<A: NativeApplication> {
    lane: String,
    request_id: String,
    deadline: Instant,
    frame: Utf8Bytes,
    warmup: bool,
    result: Result<(OwnedAttempt<A>, A::Identity), ProtocolError>,
}

type Uploads = FuturesUnordered<BoxFuture<'static, (String, String, Result<Instant, SocketEnd>)>>;

struct Session<A: NativeApplication> {
    app: Arc<A>,
    options: NativeOptions,
    downstream: Peer<IngressMessage>,
    upstream: Option<Peer<UpstreamPacket>>,
    fixed_identity: Option<A::Identity>,
    replacing_refused_socket: bool,
    reader: SharedReader<A>,
    attempts: HashMap<String, (String, OwnedAttempt<A>)>,
    admissions: FuturesUnordered<BoxFuture<'static, Admission<A>>>,
    admitting_lanes: HashSet<String>,
    uploads: Uploads,
    lanes: HashSet<String>,
    queue: VecDeque<Command>,
    blocked: Option<(Command, Instant)>,
    life: Instant,
    idle: Instant,
    received_first: bool,
    disconnected: Option<(SocketEnd, Instant)>,
    control_tokens: f64,
    control_tick: Instant,
}

/// Own ingress and provider I/O until close, including bounded settlement reads after disconnect.
pub async fn serve_native<A: NativeApplication>(
    socket: DownstreamSocket,
    app: Arc<A>,
    options: NativeOptions,
    cancellation: &CancellationToken,
) -> NativeEnd {
    let now = Instant::now();
    let mut session = Session {
        app,
        options,
        downstream: Peer::ingress(socket, MAX_EVENT_BYTES + 1024),
        upstream: None,
        fixed_identity: None,
        replacing_refused_socket: false,
        reader: Arc::new(Mutex::new(ReaderState::new())),
        attempts: HashMap::new(),
        admissions: FuturesUnordered::new(),
        admitting_lanes: HashSet::new(),
        uploads: FuturesUnordered::new(),
        lanes: HashSet::new(),
        queue: VecDeque::new(),
        blocked: None,
        life: now + CONNECTION_LIFETIME,
        idle: now + FIRST_CREATE,
        received_first: false,
        disconnected: None,
        control_tokens: 20.0,
        control_tick: now,
    };
    let end = tokio::select! {
        biased;
        _ = cancellation.cancelled() => NativeEnd::Cancelled,
        end = session.run() => end,
    };
    session.shutdown(&end, cancellation).await;
    end
}

impl<A: NativeApplication> Session<A> {
    async fn run(&mut self) -> NativeEnd {
        loop {
            if let Some((end, _)) = self.disconnected
                && self.attempts.is_empty()
            {
                return NativeEnd::Downstream(end);
            }
            let result = match self.schedule().await {
                Ok(()) => self.step().await,
                Err(end) => Err(end),
            };
            match result {
                Ok(()) => {}
                Err(NativeEnd::Downstream(end))
                    if self.disconnected.is_none() && end != SocketEnd::Congested =>
                {
                    if let Err(end) = self.disconnect(end).await {
                        return end;
                    }
                }
                Err(end) => return end,
            }
        }
    }

    async fn step(&mut self) -> Result<(), NativeEnd> {
        let next_timer = self.next_timer();
        tokio::select! {
            biased;
            _ = sleep_until(next_timer) => self.expire().map_or(Ok(()), Err),
            Some((lane, id, result)) = self.uploads.next(), if !self.uploads.is_empty() => {
                if self.attempts.get(&lane).is_some_and(|(request, _)| *request == id)
                    && let Some(turn) = self.reader.lock().expect("provider reader state").turns.active.get_mut(&lane)
                    && let Ok(sent) = result
                {
                    turn.sent = Some(sent);
                }
                Ok(())
            }
            packet = recv_upstream(&mut self.upstream), if self.upstream.is_some() => {
                match packet {
                    Ok(packet) => self.upstream_event(packet).await,
                    Err(SocketEnd::Close(1009)) if self.can_refuse_size() => self.refuse_size().await,
                    Err(end) => Err(NativeEnd::Upstream(end)),
                }
            }
            packet = self.downstream.recv(), if self.disconnected.is_none() && self.blocked.is_none() => {
                match packet {
                    Ok(packet) => self.client_message(packet).await,
                    Err(end) => Err(NativeEnd::Downstream(end)),
                }
            }
            Some(admission) = self.admissions.next(), if !self.admissions.is_empty() =>
                self.admitted(admission).await,
        }
    }

    async fn client_message(&mut self, packet: Packet<IngressMessage>) -> Result<(), NativeEnd> {
        let parsed = decode_client_message(packet.event.text.as_bytes()).and_then(|document| {
            websocket_lane(&document)?;
            if document.get("type").and_then(JsonValue::as_str).is_none() {
                return Err(UNSUPPORTED_CONTROL);
            }
            Ok(document)
        });
        let document = match parsed {
            Ok(document) => document,
            Err(error) => {
                self.send_error(error, None, &request_id(), "").await?;
                return if self.received_first {
                    Ok(())
                } else {
                    Err(NativeEnd::Protocol(error))
                };
            }
        };
        let lane = websocket_lane(&document).expect("validated lane");
        let kind = document
            .get("type")
            .and_then(JsonValue::as_str)
            .expect("validated type");
        if kind != "response.create" {
            return self
                .client_control(packet.event.text, &document, lane, kind)
                .await;
        }
        if !lane.is_empty() && !self.lanes.contains(lane) && self.lanes.len() == MAX_LANES {
            return Err(NativeEnd::Protocol(ProtocolError::new(
                503,
                "websocket_lane_capacity",
            )));
        }
        if !lane.is_empty() {
            self.lanes.insert(lane.to_owned());
        }
        // The first valid create is parsed before admitting or connecting. After that we retain
        // raw queued messages, so tools inherited from an earlier turn can be resolved in FIFO.
        let command = Command {
            packet,
            lane: lane.to_owned(),
        };
        if self.queue_fits(&command) {
            self.queue.push_back(command);
        } else {
            self.blocked = Some((command, Instant::now() + QUEUE_TIMEOUT));
        }
        Ok(())
    }

    fn queue_fits(&self, command: &Command) -> bool {
        self.queue.len() < MAX_QUEUE
            && self
                .queue
                .iter()
                .filter(|queued| queued.lane == command.lane)
                .count()
                < MAX_LANE_QUEUE
    }

    fn next_command(&self) -> Option<usize> {
        self.queue.iter().position(|command| {
            !self.admitting_lanes.contains(&command.lane)
                && !self.attempts.contains_key(&command.lane)
        })
    }

    async fn schedule(&mut self) -> Result<(), NativeEnd> {
        if self.disconnected.is_some()
            || self.downstream.read_closed().is_cancelled()
            || self
                .upstream
                .as_ref()
                .is_some_and(|peer| peer.read_closed().is_cancelled())
            || (self.upstream.is_none() && !self.admitting_lanes.is_empty())
        {
            return Ok(());
        }
        while let Some(index) = self.next_command() {
            if self.admitting_lanes.len() + self.attempts.len() >= MAX_ACTIVE {
                return Err(NativeEnd::Protocol(ProtocolError::new(
                    503,
                    "websocket_turn_capacity",
                )));
            }
            let Command { lane, packet } = self.queue.remove(index).expect("queued command");
            let request_id = request_id();
            let prepared = decode_client_message(packet.event.text.as_bytes())
                .and_then(|document| {
                    let continuation = document
                        .get("previous_response_id")
                        .is_some_and(|id| *id != JsonValue::Null);
                    if self.replacing_refused_socket && continuation {
                        return Err(ProtocolError::new(409, "upstream_state_lost"));
                    }
                    self.app.prepare(&lane, document)
                })
                .and_then(|prepared| {
                    if prepared.frame.len() > WS_ROUTING_BYTES {
                        Err(TOO_LARGE)
                    } else {
                        Ok(prepared)
                    }
                });
            let prepared = match prepared {
                Ok(prepared) => prepared,
                Err(error) => {
                    self.send_error(
                        error,
                        None,
                        &request_id,
                        if self.received_first { &lane } else { "" },
                    )
                    .await?;
                    if !self.received_first {
                        return Err(NativeEnd::Protocol(error));
                    }
                    continue;
                }
            };
            self.received_first = true;
            let lease = packet.event.lease;
            let app = self.app.clone();
            let identity = self.fixed_identity.clone();
            let deadline = self.life.min(Instant::now() + self.options.budget.total);
            self.admitting_lanes.insert(lane.clone());
            self.admissions.push(
                async move {
                    // Carry the shared lease into the execution owner, without retaining client bytes.
                    let result =
                        timeout_at(deadline, app.admit(prepared.admission, identity, deadline))
                            .await
                            .unwrap_or(Err(DEADLINE))
                            .map(|admitted| {
                                (
                                    OwnedAttempt {
                                        app,
                                        attempt: Some(Arc::new(admitted.attempt)),
                                        reader: None,
                                        _lease: lease,
                                        cancelled: false,
                                    },
                                    admitted.identity,
                                )
                            });
                    Admission {
                        lane,
                        request_id,
                        deadline,
                        frame: prepared.frame,
                        warmup: prepared.warmup,
                        result,
                    }
                }
                .boxed(),
            );
            if self.upstream.is_none() {
                break;
            }
        }
        if let Some((blocked, deadline)) = self.blocked.take() {
            if self.queue_fits(&blocked) {
                self.queue.push_back(blocked);
            } else {
                self.blocked = Some((blocked, deadline));
            }
        }
        Ok(())
    }

    async fn admitted(&mut self, admission: Admission<A>) -> Result<(), NativeEnd> {
        let Admission {
            lane,
            request_id,
            deadline,
            frame,
            warmup,
            result,
        } = admission;
        self.admitting_lanes.remove(&lane);
        let (mut attempt, identity) = match result {
            Ok(result) => result,
            Err(error) => {
                self.send_error(error, None, &request_id, &lane).await?;
                if self.upstream.is_none() && !self.replacing_refused_socket {
                    return Err(NativeEnd::Protocol(error));
                }
                self.update_idle();
                return Ok(());
            }
        };
        if self
            .fixed_identity
            .as_ref()
            .is_some_and(|fixed| fixed != &identity)
        {
            let error = ProtocolError::new(409, "upstream_state_lost");
            attempt.finish(NativeFinish::BeforeDispatch {
                protocol: error,
                provider: None,
            });
            self.send_error(error, None, &request_id, &lane).await?;
            self.update_idle();
            return Ok(());
        }
        if self.upstream.is_none() {
            let read_closed = self.downstream.read_closed();
            let result = tokio::select! {
                biased;
                _ = read_closed.cancelled() => return Err(NativeEnd::Downstream(SocketEnd::Eof)),
                result = timeout_at(deadline, self.app.connect(&identity, deadline)) =>
                    result.unwrap_or(Err(ConnectFailure::TimedOut)),
            };
            match result {
                Ok(socket) => {
                    let reader = self.reader.clone();
                    let app = self.app.clone();
                    self.upstream = Some(Peer::provider(
                        socket,
                        MAX_EVENT_BYTES,
                        DOWNSTREAM_QUEUE_BYTES,
                        move |text| {
                            let document = match decode_event(text.as_bytes()) {
                                Ok(document) => document,
                                Err(error) => return Read::Stop(Err(error)),
                            };
                            reader.lock().expect("provider reader state").inspect(
                                app.as_ref(),
                                document,
                                text.len(),
                            )
                        },
                    ));
                    self.fixed_identity = Some(identity);
                    self.replacing_refused_socket = false;
                }
                Err(error) => {
                    let (error, provider) = match error {
                        ConnectFailure::Rejected(failure) => (failure.protocol, Some(failure)),
                        ConnectFailure::TimedOut => (
                            if Instant::now() >= deadline {
                                DEADLINE
                            } else {
                                ProtocolError::new(502, "upstream_connect_failed")
                            },
                            None,
                        ),
                        _ => (ProtocolError::new(502, "upstream_connect_failed"), None),
                    };
                    let frame = websocket_error(error, provider.as_deref(), &request_id, &lane);
                    attempt.finish(NativeFinish::BeforeDispatch {
                        protocol: error,
                        provider,
                    });
                    self.send(frame, self.life).await?;
                    return Err(NativeEnd::Protocol(error));
                }
            }
        }

        if self.downstream.read_closed().is_cancelled() {
            return self.disconnect(SocketEnd::Eof).await;
        }
        let upstream = self.upstream.as_ref().expect("bound socket");
        if upstream.read_closed().is_cancelled() {
            attempt.finish(NativeFinish::BeforeDispatch {
                protocol: INDETERMINATE,
                provider: None,
            });
            return Ok(());
        }
        // A request accepted by the writer can have reached the provider even if flush fails.
        attempt.register(
            self.reader.clone(),
            lane.clone(),
            Turn::new(deadline, warmup),
        );
        self.attempts
            .insert(lane.clone(), (request_id.clone(), attempt));
        let receipt = upstream
            .queue(frame, deadline)
            .await
            .map_err(NativeEnd::Upstream)?;
        self.uploads
            .push(async move { (lane, request_id, receipt.wait().await) }.boxed());
        Ok(())
    }

    fn can_refuse_size(&self) -> bool {
        let reader = self.reader.lock().expect("provider reader state");
        self.disconnected.is_none()
            && reader.turns.active.len() == 1
            && reader.turns.active.values().all(|turn| !turn.processed)
    }

    async fn refuse_size(&mut self) -> Result<(), NativeEnd> {
        let lane = self
            .reader
            .lock()
            .expect("provider reader state")
            .turns
            .active
            .keys()
            .next()
            .expect("one active turn")
            .clone();
        let request_id = self.attempts[&lane].0.clone();
        self.queue.clear();
        self.blocked = None;
        self.admissions.clear();
        self.admitting_lanes.clear();
        self.uploads.clear();
        if let Some(mut upstream) = self.upstream.take() {
            upstream.stop().await;
        }
        self.finish_lane(&lane, NativeFinish::UnprocessedSizeRefusal);
        self.replacing_refused_socket = true;
        self.send_error(TOO_LARGE, None, &request_id, &lane).await
    }

    async fn upstream_event(&mut self, packet: Packet<UpstreamPacket>) -> Result<(), NativeEnd> {
        let RoutedEvent {
            mut document,
            route,
        } = packet.event.map_err(NativeEnd::Protocol)?;
        match route {
            Route::Ignore => Ok(()),
            Route::Detached(lane) => {
                if self.disconnected.is_none() {
                    if document.get("type").and_then(JsonValue::as_str) == Some("error") {
                        let failure = provider_failure(&document);
                        self.send_error(failure.protocol, Some(&failure), &request_id(), &lane)
                            .await?;
                    } else {
                        self.forward(&mut document, &lane, self.life).await?;
                    }
                }
                Ok(())
            }
            Route::Turn {
                lane,
                terminal,
                provider_error,
            } => {
                self.turn_event(&lane, document, terminal, provider_error)
                    .await
            }
        }
    }

    async fn turn_event(
        &mut self,
        lane: &str,
        mut document: JsonValue,
        terminal: bool,
        provider_error: bool,
    ) -> Result<(), NativeEnd> {
        let Some((request_id, attempt)) = self.attempts.get(lane) else {
            // A disconnected, timed-out lane may already have relinquished its attempt.
            return Ok(());
        };
        let deadline = self
            .reader
            .lock()
            .expect("provider reader state")
            .turns
            .active[lane]
            .deadline;
        if provider_error {
            let failure = provider_failure(&document);
            let frame = websocket_error(failure.protocol, Some(&failure), request_id, lane);
            self.finish_lane(
                lane,
                NativeFinish::Provider {
                    failure: Box::new(failure),
                    client_cancelled: self.disconnected.is_some(),
                },
            );
            if self.disconnected.is_none() {
                self.send(frame, deadline).await?;
            }
            return Ok(());
        }
        if self.disconnected.is_some() {
            if terminal {
                self.finish_lane(
                    lane,
                    NativeFinish::Terminal {
                        client_cancelled: true,
                    },
                );
            } else {
                self.interrupt_dispatched().await?;
            }
            return Ok(());
        }
        let downstream_closed = self.downstream.read_closed();
        let binding = tokio::select! {
            biased;
            _ = downstream_closed.cancelled() => {
                self.disconnect(SocketEnd::Eof).await?;
                if terminal {
                    self.finish_lane(lane, NativeFinish::Terminal { client_cancelled: true });
                }
                return Ok(());
            }
            binding = timeout_at(deadline, self.app.before_output(attempt.attempt(), &document)) =>
                binding.unwrap_or(Err(DEADLINE)),
        };
        if let Err(error) = binding {
            return Err(NativeEnd::Protocol(error));
        }
        self.forward(&mut document, lane, deadline).await?;
        if terminal {
            self.finish_lane(
                lane,
                NativeFinish::Terminal {
                    client_cancelled: self.disconnected.is_some(),
                },
            );
        }
        Ok(())
    }

    async fn client_control(
        &mut self,
        original: Utf8Bytes,
        document: &JsonValue,
        lane: &str,
        kind: &str,
    ) -> Result<(), NativeEnd> {
        if original.len() > WS_ROUTING_BYTES {
            return self.send_error(TOO_LARGE, None, &request_id(), lane).await;
        }
        if kind == "response.interrupt" {
            let id = document
                .get("response_id")
                .and_then(JsonValue::as_str)
                .unwrap_or("");
            let explicit = document.get("stream_id").map(|_| lane);
            let interrupt = self
                .reader
                .lock()
                .expect("provider reader state")
                .turns
                .interrupt(id, explicit, true);
            return match interrupt {
                Interrupt::Duplicate => Ok(()),
                Interrupt::Send(_) => self.send_control(original, self.life).await,
                Interrupt::Missing => {
                    self.send(control("response.interrupt.failed", id, lane), self.life)
                        .await
                }
            };
        }
        if self.upstream.is_none()
            || ["input", "model", "tools"]
                .iter()
                .any(|key| document.get(key).is_some())
            || !self.admit_control()
        {
            return self
                .send_error(UNSUPPORTED_CONTROL, None, &request_id(), lane)
                .await;
        }
        self.send_control(original, self.life).await
    }

    fn admit_control(&mut self) -> bool {
        let now = Instant::now();
        self.control_tokens =
            (self.control_tokens + 10.0 * (now - self.control_tick).as_secs_f64()).min(20.0);
        self.control_tick = now;
        if self.control_tokens < 1.0 {
            return false;
        }
        self.control_tokens -= 1.0;
        true
    }

    async fn disconnect(&mut self, end: SocketEnd) -> Result<(), NativeEnd> {
        if self.disconnected.is_none() {
            self.disconnected = Some((end, Instant::now() + DISCONNECT_DRAIN));
            self.queue.clear();
            self.blocked = None;
            self.admissions.clear();
            self.admitting_lanes.clear();
            self.downstream.stop().await;
            for (_, attempt) in self.attempts.values_mut() {
                attempt.cancelled = true;
            }
        }
        self.interrupt_dispatched().await
    }

    async fn interrupt_dispatched(&mut self) -> Result<(), NativeEnd> {
        let targets: Vec<_> = self
            .reader
            .lock()
            .expect("provider reader state")
            .turns
            .active
            .iter()
            .filter_map(|(lane, turn)| {
                (!turn.interrupted && !turn.provider_done)
                    .then(|| {
                        Some((
                            lane.clone(),
                            turn.response_id.as_ref()?.clone(),
                            turn.deadline,
                        ))
                    })
                    .flatten()
            })
            .collect();
        for (lane, id, deadline) in targets {
            let deadline = deadline.min(self.disconnected.expect("draining").1);
            if Instant::now() >= deadline {
                continue;
            }
            let interrupt = self
                .reader
                .lock()
                .expect("provider reader state")
                .turns
                .interrupt(&id, Some(&lane), false);
            if let Interrupt::Send(owner) = interrupt {
                self.send_control(control("response.interrupt", &id, &owner), deadline)
                    .await?;
            }
        }
        Ok(())
    }

    fn next_timer(&self) -> Instant {
        let mut deadline = self
            .reader
            .lock()
            .expect("provider reader state")
            .turns
            .active
            .values()
            .map(|turn| turn.expiry(self.options.budget).0)
            .min()
            .unwrap_or(self.life)
            .min(self.life);
        if let Some((_, stop)) = self.disconnected {
            return deadline.min(stop);
        }
        if let Some((_, stop)) = &self.blocked {
            deadline = deadline.min(*stop);
        }
        if !self.received_first || self.is_empty() {
            deadline = deadline.min(self.idle);
        }
        deadline
    }

    fn expire(&mut self) -> Option<NativeEnd> {
        let now = Instant::now();
        if self.life <= now {
            return Some(NativeEnd::Lifetime);
        }
        if let Some((end, stop)) = self.disconnected
            && stop <= now
        {
            return Some(NativeEnd::Downstream(end));
        }
        if self.blocked.as_ref().is_some_and(|(_, stop)| *stop <= now) {
            return Some(NativeEnd::Downstream(SocketEnd::Congested));
        }
        if (!self.received_first || self.is_empty()) && self.idle <= now {
            return Some(NativeEnd::Idle);
        }
        let expired: Vec<_> = self
            .reader
            .lock()
            .expect("provider reader state")
            .turns
            .active
            .iter()
            .filter_map(|(lane, turn)| {
                let (expires, error) = turn.expiry(self.options.budget);
                (expires <= now).then(|| (lane.clone(), error))
            })
            .collect();
        if !expired.is_empty() && self.disconnected.is_none() {
            // An expired turn may still emit on the provider connection. End ownership before a
            // new create in that lane could accidentally claim those late events.
            let (lane, protocol) = expired.into_iter().next().expect("expired turn");
            return Some(NativeEnd::TurnTimeout { lane, protocol });
        }
        for (lane, protocol) in expired {
            self.finish_lane(
                &lane,
                NativeFinish::Indeterminate {
                    protocol,
                    socket: None,
                    client_cancelled: true,
                },
            );
        }
        None
    }

    fn is_empty(&self) -> bool {
        self.attempts.is_empty()
            && self.admissions.is_empty()
            && self.queue.is_empty()
            && self.blocked.is_none()
    }

    fn update_idle(&mut self) {
        if self.is_empty() {
            self.idle = Instant::now() + CONNECTION_IDLE;
        }
    }

    fn finish_lane(&mut self, lane: &str, result: NativeFinish) {
        if let Some((_, attempt)) = self.attempts.remove(lane) {
            attempt.finish(result);
        }
        self.update_idle();
    }

    async fn shutdown(&mut self, end: &NativeEnd, cancellation: &CancellationToken) {
        self.queue.clear();
        self.blocked = None;
        self.admissions.clear();
        self.uploads.clear();
        if let Some(upstream) = self.upstream.as_mut() {
            upstream.stop().await;
        }
        let snapshot: Vec<_> = self.attempts.keys().cloned().collect();
        let size_refusal = matches!(end, NativeEnd::Upstream(SocketEnd::Close(1009)))
            && snapshot.len() == 1
            && !self
                .reader
                .lock()
                .expect("provider reader state")
                .turns
                .active[&snapshot[0]]
                .processed;
        let protocol = match end {
            NativeEnd::Protocol(error) => *error,
            NativeEnd::Upstream(SocketEnd::MessageTooLarge) => {
                ProtocolError::new(502, "upstream_event_too_large")
            }
            _ => INDETERMINATE,
        };
        let socket = match end {
            NativeEnd::Upstream(end) | NativeEnd::Downstream(end) => Some(*end),
            NativeEnd::Cancelled => Some(SocketEnd::Cancelled),
            _ => None,
        };
        let mut errors = Vec::new();
        for lane in snapshot {
            let (id, attempt) = &self.attempts[&lane];
            let cancelled = attempt.cancelled || matches!(end, NativeEnd::Downstream(_));
            let protocol = match end {
                NativeEnd::TurnTimeout {
                    lane: expired,
                    protocol,
                } if expired == &lane => *protocol,
                _ => protocol,
            };
            let result = if size_refusal {
                NativeFinish::UnprocessedSizeRefusal
            } else {
                NativeFinish::Indeterminate {
                    protocol,
                    socket,
                    client_cancelled: cancelled,
                }
            };
            if !cancelled {
                errors.push(websocket_error(
                    if size_refusal { TOO_LARGE } else { protocol },
                    None,
                    id,
                    &lane,
                ));
            }
            self.finish_lane(&lane, result);
        }
        if matches!(end, NativeEnd::Cancelled | NativeEnd::Downstream(_))
            || self.disconnected.is_some()
        {
            self.downstream.stop().await;
            return;
        }
        let deadline = Instant::now() + QUEUE_TIMEOUT;
        tokio::select! {
            _ = cancellation.cancelled() => self.downstream.stop().await,
            _ = async {
                for error in errors {
                    if self.downstream.send(error, deadline).await.is_err() {
                        break;
                    }
                }
                self.downstream.close(CloseCode::Normal).await;
            } => {}
        }
    }

    async fn forward(
        &mut self,
        document: &mut JsonValue,
        lane: &str,
        deadline: Instant,
    ) -> Result<(), NativeEnd> {
        sanitize_client_output(document);
        if let Some(fields) = document.as_object_mut() {
            with_lane(fields, lane);
        }
        let encoded = Utf8Bytes::try_from(document.encode(false)).expect("UTF-8 JSON");
        if let Err(NativeEnd::Downstream(end)) = self.send(encoded, deadline).await {
            return self.disconnect(end).await;
        }
        Ok(())
    }

    async fn send(&mut self, frame: Utf8Bytes, deadline: Instant) -> Result<(), NativeEnd> {
        self.downstream
            .send(frame, deadline.min(Instant::now() + QUEUE_TIMEOUT))
            .await
            .map(|_| ())
            .map_err(NativeEnd::Downstream)
    }

    async fn send_control(&mut self, frame: Utf8Bytes, deadline: Instant) -> Result<(), NativeEnd> {
        self.upstream
            .as_ref()
            .expect("active socket")
            .send(frame, deadline.min(Instant::now() + QUEUE_TIMEOUT))
            .await
            .map(|_| ())
            .map_err(NativeEnd::Upstream)
    }

    async fn send_error(
        &mut self,
        error: ProtocolError,
        provider: Option<&ProviderFailure>,
        id: &str,
        lane: &str,
    ) -> Result<(), NativeEnd> {
        self.send(websocket_error(error, provider, id, lane), self.life)
            .await
    }
}

async fn recv_upstream(
    upstream: &mut Option<Peer<UpstreamPacket>>,
) -> Result<Packet<UpstreamPacket>, SocketEnd> {
    match upstream {
        Some(upstream) => upstream.recv().await,
        None => pending().await,
    }
}

fn request_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
