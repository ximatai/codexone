use std::sync::{Arc, Mutex};

use codexone_responses::{
    EventSemantics, JsonValue, MAX_EVENT_BYTES, ProtocolError, ProviderFailure,
    sanitize_client_output,
};
use tokio::time::{Instant, sleep_until, timeout_at};
use tokio_tungstenite::tungstenite::Utf8Bytes;

use crate::{
    CancellationToken, ConnectFailure, ExecutionBudget, QUEUE_TIMEOUT, Socket, SocketEnd,
    WS_ROUTING_BYTES,
    peer::{DOWNSTREAM_QUEUE_BYTES, Peer, Read},
    protocol::{DEADLINE, INDETERMINATE, TOO_LARGE},
    turns::{Route, Turn, Turns, decode_event, provider_failure},
};

#[derive(Debug)]
pub enum BridgeRoute {
    WebSocket(Utf8Bytes),
    Http,
}

/// Classify the final encoded payload before dispatch. Caller retains the same admission,
/// authorization and deadline for a permitted HTTP fallback.
pub fn bridge_route(frame: Utf8Bytes, continuation: bool) -> Result<BridgeRoute, ProtocolError> {
    if frame.len() <= WS_ROUTING_BYTES {
        Ok(BridgeRoute::WebSocket(frame))
    } else if continuation {
        Err(TOO_LARGE)
    } else {
        Ok(BridgeRoute::Http)
    }
}

#[derive(Debug)]
pub enum BridgeFailure {
    BeforeSend(ConnectFailure),
    UnprocessedSizeRefusal {
        http_fallback: bool,
    },
    Provider(Box<ProviderFailure>),
    Interrupted {
        protocol: ProtocolError,
        socket: Option<SocketEnd>,
    },
}

pub struct BridgeOptions {
    pub deadline: Instant,
    pub budget: ExecutionBudget,
    pub stream: bool,
    pub continuation: bool,
    pub cancellation: CancellationToken,
}

#[derive(Debug)]
pub struct BridgeOutput {
    pub document: JsonValue,
    pub terminal: bool,
}

pub enum BridgeEvidence<'a> {
    Event(&'a JsonValue),
    PossibleProcessing,
}

struct Exchange {
    options: BridgeOptions,
    turns: Arc<Mutex<Turns>>,
    buffered_metadata: Vec<JsonValue>,
    visible: bool,
}

/// Run one fresh provider socket. The synchronous observer receives correlated raw evidence before
/// downstream output. The output callback applies binding barriers and writes the client JSON/SSE.
/// The owner of the HTTP response supplies the SSE finish marker after durable finalization.
pub async fn bridge<E, F, O>(
    connect: impl Future<Output = Result<Socket, ConnectFailure>>,
    frame: Utf8Bytes,
    options: BridgeOptions,
    mut evidence: E,
    mut output: O,
) -> Result<(), BridgeFailure>
where
    E: FnMut(BridgeEvidence<'_>) + Send + 'static,
    O: FnMut(BridgeOutput) -> F,
    F: Future<Output = Result<(), ProtocolError>>,
{
    if frame.len() > WS_ROUTING_BYTES {
        return Err(BridgeFailure::UnprocessedSizeRefusal {
            http_fallback: !options.continuation,
        });
    }
    let socket = tokio::select! {
        biased;
        _ = options.cancellation.cancelled() => Err(ConnectFailure::Cancelled),
        result = timeout_at(options.deadline, connect) =>
            result.unwrap_or(Err(ConnectFailure::TimedOut)),
    }
    .map_err(BridgeFailure::BeforeSend)?;
    let mut turns = Turns::new();
    turns
        .active
        .insert(String::new(), Turn::new(options.deadline, false));
    let turns = Arc::new(Mutex::new(turns));
    let reader = turns.clone();
    let mut peer = Peer::provider(
        socket,
        MAX_EVENT_BYTES,
        DOWNSTREAM_QUEUE_BYTES,
        move |frame| match inspect(&mut reader.lock().unwrap(), frame, &mut evidence) {
            Ok(Some(event)) => Read::Deliver(Ok(event)),
            Ok(None) => Read::Ignore,
            Err(error) => Read::Stop(Err(error)),
        },
    );
    let mut exchange = Exchange {
        options,
        turns,
        buffered_metadata: Vec::new(),
        visible: false,
    };
    let result = exchange.run(&mut peer, frame, &mut output).await;
    if result.is_err()
        && !matches!(result, Err(BridgeFailure::UnprocessedSizeRefusal { .. }))
        && !exchange.options.cancellation.is_cancelled()
    {
        for document in std::mem::take(&mut exchange.buffered_metadata) {
            if exchange.emit(document, false, &mut output).await.is_err() {
                break;
            }
        }
    }
    peer.stop().await;
    result
}

impl Exchange {
    async fn run<F, O>(
        &mut self,
        peer: &mut Peer<Result<TurnEvent, ProtocolError>>,
        frame: Utf8Bytes,
        output: &mut O,
    ) -> Result<(), BridgeFailure>
    where
        O: FnMut(BridgeOutput) -> F,
        F: Future<Output = Result<(), ProtocolError>>,
    {
        let deadline = self.options.deadline;
        let receipt = peer.queue(frame, deadline).await.map_err(interrupted)?;
        let upload = receipt.wait();
        tokio::pin!(upload);
        let mut uploaded = false;
        loop {
            let (expires, _) = self.expiry();
            let packet = tokio::select! {
                biased;
                _ = self.options.cancellation.cancelled() =>
                    return Err(interrupted(SocketEnd::Cancelled)),
                _ = sleep_until(expires) => {
                    let (expires, failure) = self.expiry();
                    if Instant::now() >= expires {
                        return Err(protocol(failure));
                    }
                    continue;
                }
                packet = peer.recv() => packet,
                result = &mut upload, if !uploaded => {
                    uploaded = true;
                    // The reader reports write failure after delivering observed events.
                    if let Ok(sent) = result {
                        self.turns.lock().unwrap().active.get_mut("").expect("bridge turn").sent = Some(sent);
                    }
                    continue;
                }
            };
            let event = match packet {
                Err(SocketEnd::Close(1009)) if !self.turns.lock().unwrap().active[""].processed => {
                    return Err(BridgeFailure::UnprocessedSizeRefusal {
                        http_fallback: !self.options.continuation,
                    });
                }
                Ok(packet) => packet.event.map_err(protocol)?,
                Err(end) => return Err(interrupted(end)),
            };
            let TurnEvent {
                document,
                terminal,
                provider_error,
            } = event;
            if provider_error {
                return Err(BridgeFailure::Provider(Box::new(provider_failure(
                    &document,
                ))));
            }
            if self.options.stream {
                if !self.visible && EventSemantics::classify(&document).connection_metadata {
                    if self.buffered_metadata.len() == 64 {
                        return Err(protocol(ProtocolError::new(
                            502,
                            "upstream_response_too_large",
                        )));
                    }
                    self.buffered_metadata.push(document);
                    continue;
                }
                for metadata in std::mem::take(&mut self.buffered_metadata) {
                    self.emit(metadata, false, output).await?;
                }
                self.visible = true;
                self.emit(document, terminal, output).await?;
            } else if terminal {
                let response = document
                    .get("response")
                    .expect("correlated terminal")
                    .clone();
                self.emit(response, true, output).await?;
            }
            if terminal {
                return Ok(());
            }
        }
    }

    fn expiry(&self) -> (Instant, ProtocolError) {
        let turns = self.turns.lock().unwrap();
        let turn = &turns.active[""];
        if turn.provider_done {
            (self.options.deadline, DEADLINE)
        } else {
            turn.expiry(self.options.budget)
        }
    }

    async fn emit<F>(
        &self,
        mut document: JsonValue,
        terminal: bool,
        output: &mut impl FnMut(BridgeOutput) -> F,
    ) -> Result<(), BridgeFailure>
    where
        F: Future<Output = Result<(), ProtocolError>>,
    {
        sanitize_client_output(&mut document);
        let now = Instant::now();
        let remaining = self.options.deadline.saturating_duration_since(now);
        let slow = remaining > QUEUE_TIMEOUT;
        let write = output(BridgeOutput { document, terminal });
        let result = tokio::select! {
            biased;
            _ = self.options.cancellation.cancelled() =>
                return Err(interrupted(SocketEnd::Cancelled)),
            result = timeout_at(now + remaining.min(QUEUE_TIMEOUT), write) => result,
        };
        result
            .unwrap_or(Err(if slow {
                ProtocolError::new(504, "client_too_slow")
            } else {
                DEADLINE
            }))
            .map_err(protocol)
    }
}

struct TurnEvent {
    document: JsonValue,
    terminal: bool,
    provider_error: bool,
}

fn inspect(
    turns: &mut Turns,
    frame: Utf8Bytes,
    evidence: &mut impl FnMut(BridgeEvidence<'_>),
) -> Result<Option<TurnEvent>, ProtocolError> {
    let document = decode_event(frame.as_bytes())?;
    if document.get("stream_id").is_some() {
        return Err(ProtocolError::new(502, "invalid_upstream_lane"));
    }
    let route = turns.observe(&document, frame.len())?;
    if std::mem::take(&mut turns.active.get_mut("").expect("bridge turn").unattributed) {
        evidence(BridgeEvidence::PossibleProcessing);
    }
    if let Route::Turn {
        terminal,
        provider_error,
        ..
    } = route
    {
        evidence(BridgeEvidence::Event(&document));
        Ok(Some(TurnEvent {
            document,
            terminal,
            provider_error,
        }))
    } else {
        Ok(None)
    }
}

fn interrupted(socket: SocketEnd) -> BridgeFailure {
    let protocol = match socket {
        SocketEnd::MessageTooLarge => ProtocolError::new(502, "upstream_event_too_large"),
        SocketEnd::InvalidFrame => ProtocolError::new(502, "invalid_upstream_frame"),
        _ => INDETERMINATE,
    };
    BridgeFailure::Interrupted {
        protocol,
        socket: Some(socket),
    }
}

fn protocol(protocol: ProtocolError) -> BridgeFailure {
    BridgeFailure::Interrupted {
        protocol,
        socket: None,
    }
}
