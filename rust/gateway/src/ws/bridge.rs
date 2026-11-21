use std::{
    pin::Pin,
    sync::{Arc, Mutex},
};

use bytes::Bytes;
use codexone_execution::{Execution, Failure};
use codexone_responses::{self as protocol, ProtocolError};
use codexone_websocket::{
    self as websocket, BridgeEvidence, BridgeFailure, BridgeOptions, BridgeOutput, SocketEnd,
    Utf8Bytes,
};
use futures_util::stream;
use http::{HeaderMap, StatusCode};
use http_body::Frame;
use tokio::sync::mpsc;

use super::{
    Connector, Provider, SizePath,
    attempt::{Attempt, connect_error},
};
use crate::{
    body_budget::BodyPermit,
    diagnostics::{self, ClientProtocolExtensions},
    headers,
    reply::{self, Delivery, FlushDeliveries, Reply},
    response::{ResponseError, Transfer},
};

pub struct BridgeRequest {
    connector: Connector,
    headers: HeaderMap,
    frame: Utf8Bytes,
    options: BridgeOptions,
    provider: Provider,
    extensions: Option<Arc<ClientProtocolExtensions>>,
}

impl BridgeRequest {
    pub fn prepare(
        connector: &Connector,
        incoming: &HeaderMap,
        forwarded: &mut HeaderMap,
        request: &protocol::Request,
        deadline: tokio::time::Instant,
        budget: websocket::ExecutionBudget,
    ) -> Result<Option<Self>, ProtocolError> {
        request.validate_contract(connector.contract, false)?;
        let states = headers::values(incoming, "x-codex-turn-state");
        let turn_state = protocol::request_turn_state(
            &states,
            &headers::values(incoming, "connection"),
            request.document(),
        )?;
        if let Some(state) = turn_state {
            forwarded.insert(
                "x-codex-turn-state",
                state
                    .parse()
                    .map_err(|_| ProtocolError::new(400, "invalid_turn_state"))?,
            );
        }
        let continuation = request
            .document()
            .get("previous_response_id")
            .is_some_and(|id| *id != protocol::JsonValue::Null);
        let frame = websocket::create_frame(request.clone(), connector.contract, "", turn_state)?;
        let size = frame.len();
        if size > websocket::WS_ROUTING_BYTES {
            super::record_size(
                if continuation {
                    SizePath::Continuation
                } else {
                    SizePath::Http
                },
                size,
            );
        }
        match websocket::bridge_route(frame, continuation)? {
            websocket::BridgeRoute::WebSocket(frame) => Ok(Some(Self {
                connector: connector.clone(),
                provider: Provider::default(),
                extensions: None,
                headers: forwarded.clone(),
                frame,
                options: BridgeOptions {
                    deadline,
                    budget,
                    stream: request.stream,
                    continuation,
                    cancellation: websocket::CancellationToken::new(),
                },
            })),
            websocket::BridgeRoute::Http => Ok(None),
        }
    }
    pub fn authorize(
        mut self,
        provider: Provider,
        extensions: Arc<ClientProtocolExtensions>,
    ) -> Self {
        self.provider = provider;
        self.extensions = Some(extensions);
        self
    }
}

pub enum BridgeResult {
    Reply(Reply),
    Fallback(Box<Execution>, BodyPermit),
}

struct TerminalFrame {
    bytes: Bytes,
    delivery: Option<Delivery>,
}

enum End {
    Terminal(Box<TerminalFrame>),
    Failed(ResponseError),
    Fallback(Box<Execution>, BodyPermit),
}

type Exchange = Pin<Box<dyn Future<Output = (End, HeaderMap)> + Send>>;

pub async fn forward(
    request: BridgeRequest,
    transfer: Transfer,
    lease: Execution,
    request_id: String,
    pending: FlushDeliveries,
    body_permit: BodyPermit,
) -> BridgeResult {
    let streaming = request.options.stream;
    let stop = lease.account_stop_token().cloned().unwrap_or_default();
    let (sender, mut receiver) = mpsc::channel(1);
    let response_headers = Arc::new(Mutex::new(HeaderMap::new()));
    let mut exchange: Exchange = Box::pin(exchange(
        request,
        transfer,
        lease,
        body_permit,
        sender,
        response_headers.clone(),
    ));
    let (end, headers) = tokio::select! {
            biased;
            _ = stop.cancelled() => (&mut exchange).await,
            Some(first) = receiver.recv(), if streaming => {
                if stop.is_cancelled() {
                    (&mut exchange).await
                } else {
                let headers = response_headers.lock().unwrap().clone();
                let stream = Output {
                    exchange: Some(exchange),
                    stop,
                    receiver,
                    first: Some(first),
                    deferred_end: None,
                    done: false,
                    request_id: request_id.clone(),
                    pending,
                };
                return BridgeResult::Reply(reply::sse(headers, &request_id, stream.frames()));
                }
            }
            result = &mut exchange => result,
    };
    if !stop.is_cancelled()
        && let Ok(first) = receiver.try_recv()
    {
        let stream = Output {
            exchange: None,
            stop,
            receiver,
            first: Some(first),
            deferred_end: Some(end),
            done: false,
            request_id: request_id.clone(),
            pending,
        };
        return BridgeResult::Reply(reply::sse(headers, &request_id, stream.frames()));
    }
    let reply = match end {
        End::Failed(error) => error.reply(&request_id, headers),
        End::Fallback(lease, body_permit) => return BridgeResult::Fallback(lease, body_permit),
        End::Terminal(terminal) if !streaming => reply::json(
            StatusCode::OK,
            terminal.bytes,
            headers,
            &request_id,
            terminal.delivery.map(|delivery| (delivery, pending)),
        ),
        End::Terminal(terminal) => {
            let stream = Output {
                exchange: None,
                stop,
                receiver,
                first: None,
                deferred_end: Some(End::Terminal(terminal)),
                done: false,
                request_id: request_id.clone(),
                pending,
            };
            reply::sse(headers, &request_id, stream.frames())
        }
    };
    BridgeResult::Reply(reply)
}

async fn exchange(
    request: BridgeRequest,
    transfer: Transfer,
    lease: Execution,
    body_permit: BodyPermit,
    sender: mpsc::Sender<Bytes>,
    response_headers: Arc<Mutex<HeaderMap>>,
) -> (End, HeaderMap) {
    let BridgeRequest {
        connector,
        headers: forwarded,
        frame,
        mut options,
        provider,
        extensions,
    } = request;
    if let Some(stop) = lease.account_stop_token() {
        options.cancellation = stop.clone();
    }
    let cancellation = options.cancellation.clone();
    let deadline = options.deadline;
    let streaming = options.stream;
    let terminal = Mutex::new(None);
    let local_error = Mutex::new(None);
    let attempt = Arc::new(Attempt::new(
        lease,
        transfer.usage,
        transfer.began,
        frame.len(),
    ));
    let attempt_ref = attempt.as_ref();
    let evidence_owner = attempt.clone();
    let evidence_headers = response_headers.clone();
    let connect = async {
        let (socket, upstream_headers) = connector
            .connect(&forwarded, &provider, deadline, &cancellation)
            .await?;
        *response_headers.lock().unwrap() = headers::provider(&upstream_headers, true);
        if let Err(error) = attempt_ref.begin_dispatch().await {
            *local_error.lock().unwrap() = Some(error);
            return Err(websocket::ConnectFailure::Cancelled);
        }
        Ok(socket)
    };
    let event_provider = provider.clone();
    let result = websocket::bridge(
        connect,
        frame,
        options,
        move |evidence| match evidence {
            BridgeEvidence::Event(event) => {
                event_provider.observe_event(event);
                if let Some(extensions) = &extensions {
                    extensions.upstream_event(event);
                }
                if !streaming {
                    apply_turn_state(event, &evidence_headers);
                }
                evidence_owner.event(event);
            }
            BridgeEvidence::PossibleProcessing => evidence_owner.possible_processing(),
        },
        |output| {
            output_frame(
                output,
                streaming,
                attempt_ref,
                &terminal,
                &sender,
                &response_headers,
            )
        },
    )
    .await;

    let response_headers = response_headers.lock().unwrap().clone();
    let mut attempt = Arc::into_inner(attempt).expect("bridge reader has stopped");
    if cancellation.is_cancelled() {
        let error = ResponseError::from(codexone_execution::ExecutionError::AccountForceStopped);
        let (lease, outcome) = attempt.finish(Some(error.failure()), None, false);
        let _ = lease.finish(Some(outcome));
        return (End::Failed(error), response_headers);
    }
    if let Some(id) = &attempt.request_id {
        match &result {
            Err(BridgeFailure::BeforeSend(error)) => {
                diagnostics::websocket_setup(id, error, attempt.credential_version)
            }
            Err(BridgeFailure::Interrupted {
                socket: Some(socket),
                ..
            }) => diagnostics::websocket_close(
                id,
                *socket,
                attempt.has_first_event(),
                attempt.credential_version,
            ),
            _ => {}
        }
    }
    let boundary = match &result {
        Err(BridgeFailure::UnprocessedSizeRefusal {
            http_fallback: true,
        }) => Some(SizePath::Http1009),
        Err(BridgeFailure::UnprocessedSizeRefusal {
            http_fallback: false,
        }) => Some(SizePath::Continuation1009),
        Err(BridgeFailure::Interrupted {
            socket: Some(SocketEnd::Close(1009)),
            ..
        }) => Some(SizePath::Indeterminate1009),
        _ => None,
    };
    if let Some(path) = boundary {
        super::record_size(path, attempt.encoded_bytes);
    }
    let end = match result {
        Ok(()) => {
            let bytes = terminal
                .into_inner()
                .unwrap()
                .expect("bridge success includes terminal");
            let (lease, outcome) = attempt.finish(None, None, false);
            let delivery = if outcome.failure.is_some() {
                let _ = lease.finish(Some(outcome));
                None
            } else {
                Some(Delivery::new(lease, outcome))
            };
            End::Terminal(Box::new(TerminalFrame { bytes, delivery }))
        }
        Err(BridgeFailure::UnprocessedSizeRefusal {
            http_fallback: true,
        }) => End::Fallback(Box::new(attempt.take_lease()), body_permit),
        Err(error) => {
            let mut provider = None;
            let size_refusal = matches!(error, BridgeFailure::UnprocessedSizeRefusal { .. });
            let error = match error {
                BridgeFailure::BeforeSend(error) => match local_error.into_inner().unwrap() {
                    Some(local) => local.into(),
                    None => {
                        if let websocket::ConnectFailure::Rejected(ref refusal) = error {
                            attempt.handshake_rejection(refusal);
                            provider = Some(refusal.clone());
                        }
                        connect_error(error, deadline)
                    }
                },
                BridgeFailure::UnprocessedSizeRefusal { .. } => {
                    ProtocolError::new(413, "conversation_too_large").into()
                }
                BridgeFailure::Provider(failure) => {
                    provider = Some(failure.clone());
                    failure.into()
                }
                BridgeFailure::Interrupted {
                    protocol,
                    socket: Some(SocketEnd::Cancelled),
                } => {
                    let (lease, outcome) =
                        attempt.finish(Some(Failure::ClientCancelled), None, false);
                    let _ = lease.finish(Some(outcome));
                    return (End::Failed(protocol.into()), response_headers);
                }
                BridgeFailure::Interrupted { protocol, .. } => protocol.into(),
            };
            let (lease, outcome) =
                attempt.finish(Some(error.failure()), provider.as_deref(), size_refusal);
            let _ = lease.finish(Some(outcome));
            End::Failed(error)
        }
    };
    (end, response_headers)
}

async fn output_frame(
    output: BridgeOutput,
    streaming: bool,
    attempt: &Attempt,
    terminal: &Mutex<Option<Bytes>>,
    sender: &mpsc::Sender<Bytes>,
    headers: &Mutex<HeaderMap>,
) -> Result<(), ProtocolError> {
    attempt.bind(&output.document, !streaming).await?;
    apply_turn_state(&output.document, headers);
    let bytes = if streaming {
        Bytes::from(protocol::encode_sse_event(&output.document)?)
    } else {
        reply::encode(&output.document)
    };
    if output.terminal {
        *terminal.lock().unwrap() = Some(bytes);
    } else {
        sender
            .send(bytes)
            .await
            .map_err(|_| ProtocolError::new(502, "execution_indeterminate"))?;
    }
    Ok(())
}

fn apply_turn_state(event: &protocol::JsonValue, headers: &Mutex<HeaderMap>) {
    if let Some(state) = protocol::response_metadata_turn_state(event)
        && let Ok(state) = state.parse()
    {
        headers
            .lock()
            .unwrap()
            .entry("x-codex-turn-state")
            .or_insert(state);
    }
}

struct Output {
    exchange: Option<Exchange>,
    stop: websocket::CancellationToken,
    receiver: mpsc::Receiver<Bytes>,
    first: Option<Bytes>,
    deferred_end: Option<End>,
    done: bool,
    request_id: String,
    pending: FlushDeliveries,
}

impl Output {
    fn frames(
        self,
    ) -> impl futures_util::Stream<Item = Result<Frame<Bytes>, std::convert::Infallible>> {
        stream::unfold(self, |mut output| async {
            let frame = output.next().await?;
            Some((Ok(Frame::data(frame)), output))
        })
    }

    async fn next(&mut self) -> Option<Bytes> {
        if let Some(first) = self.first.take()
            && !self.stop.is_cancelled()
        {
            return Some(first);
        }
        if let Some(exchange) = &mut self.exchange {
            let (end, _) = tokio::select! {
                biased;
                _ = self.stop.cancelled() => (&mut *exchange).await,
                Some(frame) = self.receiver.recv() => {
                    if !self.stop.is_cancelled() {
                        return Some(frame);
                    }
                    (&mut *exchange).await
                }
                result = &mut *exchange => result,
            };
            self.exchange = None;
            self.deferred_end = Some(end);
        }
        if !self.stop.is_cancelled()
            && let Ok(frame) = self.receiver.try_recv()
        {
            return Some(frame);
        }
        match self.deferred_end.take() {
            Some(End::Terminal(terminal)) => {
                if let Some(delivery) = terminal.delivery {
                    self.pending.enqueue(delivery);
                }
                self.done = true;
                Some(terminal.bytes)
            }
            Some(End::Failed(error)) => Some(error.streaming_frame(&self.request_id)),
            Some(End::Fallback(..)) => unreachable!("size refusal after visible output"),
            None if std::mem::take(&mut self.done) => {
                self.pending.wait().await;
                Some(Bytes::from_static(protocol::DONE_FRAME))
            }
            None => None,
        }
    }
}
