use codexone_responses::{
    EventSemantics, JsonValue, MAX_EVENT_BYTES, ProtocolError, ProviderFailure,
    sanitize_client_output,
};
use tokio::time::{Instant, sleep_until, timeout_at};
use tokio_tungstenite::tungstenite::Utf8Bytes;

use crate::{
    CancellationToken, ConnectFailure, ExecutionBudget, QUEUE_TIMEOUT, Socket, SocketEnd,
    WS_ROUTING_BYTES,
    peer::{DOWNSTREAM_QUEUE_BYTES, Peer},
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
    turns: Turns,
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
    E: FnMut(BridgeEvidence<'_>),
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
    let mut peer = Peer::new(socket, MAX_EVENT_BYTES, DOWNSTREAM_QUEUE_BYTES);
    let mut exchange = Exchange {
        options,
        turns: Turns::new(),
        buffered_metadata: Vec::new(),
        visible: false,
    };
    let result = exchange
        .run(&mut peer, frame, &mut evidence, &mut output)
        .await;
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
    async fn run<E, F, O>(
        &mut self,
        peer: &mut Peer,
        frame: Utf8Bytes,
        evidence: &mut E,
        output: &mut O,
    ) -> Result<(), BridgeFailure>
    where
        E: FnMut(BridgeEvidence<'_>),
        O: FnMut(BridgeOutput) -> F,
        F: Future<Output = Result<(), ProtocolError>>,
    {
        let deadline = self.options.deadline;
        let receipt = peer.queue(frame, deadline).await.map_err(interrupted)?;
        let upload = receipt.wait();
        tokio::pin!(upload);
        let mut uploaded = false;
        self.turns
            .active
            .insert(String::new(), Turn::new(deadline, false));
        loop {
            let (expires, failure) = self.turns.active[""].expiry(self.options.budget);
            let packet = tokio::select! {
                biased;
                _ = self.options.cancellation.cancelled() =>
                    return Err(interrupted(SocketEnd::Cancelled)),
                _ = sleep_until(expires) => return Err(protocol(failure)),
                packet = peer.recv() => packet,
                result = &mut upload, if !uploaded => {
                    uploaded = true;
                    match result {
                        Ok(sent) => self.turns.active.get_mut("").expect("bridge turn").sent = Some(sent),
                        Err(_) if Instant::now() >= deadline => return Err(protocol(DEADLINE)),
                        // A close may have reached the sole reader ahead of the writer failure.
                        Err(_) => {}
                    }
                    continue;
                }
            };
            let packet = match packet {
                Err(SocketEnd::Close(1009)) if !self.turns.active[""].processed => {
                    return Err(BridgeFailure::UnprocessedSizeRefusal {
                        http_fallback: !self.options.continuation,
                    });
                }
                Ok(packet) => packet,
                Err(end) => return Err(interrupted(end)),
            };
            let document = decode_event(packet.text.as_bytes()).map_err(protocol)?;
            if document.get("stream_id").is_some() {
                return Err(protocol(ProtocolError::new(502, "invalid_upstream_lane")));
            }
            let route = self
                .turns
                .observe(&document, packet.text.len())
                .map_err(protocol)?;
            if std::mem::take(
                &mut self
                    .turns
                    .active
                    .get_mut("")
                    .expect("bridge turn")
                    .unattributed,
            ) {
                evidence(BridgeEvidence::PossibleProcessing);
            }
            if let Route::Turn {
                terminal,
                provider_error,
                ..
            } = route
            {
                evidence(BridgeEvidence::Event(&document));
                if provider_error {
                    return Err(BridgeFailure::Provider(Box::new(provider_failure(
                        &document,
                    ))));
                }
                if self.options.stream {
                    if !self.visible && EventSemantics::classify(&document).connection_metadata {
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
