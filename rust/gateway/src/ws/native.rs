use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

use codexone_config::ResponsesConfiguration;
use codexone_execution::{self as execution, Failure};
use codexone_responses::{self as protocol, JsonValue, ProtocolError, UsageConfig};
use codexone_websocket::{
    self as websocket, Admitted, CancellationToken, ConnectFailure, NativeApplication,
    NativeEvidence, NativeFinish, NativeOptions, PreparedCreate, Socket,
};
use http::HeaderMap;
use hyper::upgrade::OnUpgrade;
use hyper_util::rt::TokioIo;
use tokio::time::Instant;

use super::{Connector, SizePath, attempt::Attempt, ingress::Ingress};
use crate::{body_budget::DataBodies, data, headers, response::ResponseError};

pub struct Upgrade {
    io: OnUpgrade,
    session: Arc<Session>,
    bodies: Arc<Ingress>,
}

impl Upgrade {
    pub fn new(io: OnUpgrade, session: Session, bodies: DataBodies) -> Self {
        Self {
            io,
            session: Arc::new(session),
            bodies: Arc::new(Ingress(bodies)),
        }
    }

    pub async fn serve(self, draining: &CancellationToken) {
        let io = tokio::select! {
            biased;
            _ = draining.cancelled() => return,
            io = self.io => match io {
                Ok(io) => io,
                Err(_) => return,
            },
        };
        let options = NativeOptions {
            budget: super::budget(self.session.config.budget, false),
        };
        let socket = websocket::downstream_socket(TokioIo::new(io), self.bodies);
        websocket::serve_native(socket, self.session, options, draining).await;
    }
}

pub struct Session {
    config: Arc<ResponsesConfiguration>,
    connector: Connector,
    execution: execution::ExecutionService,
    authorization: execution::StaticAuthorization,
    forwarded: HeaderMap,
    first_attempt: OnceLock<String>,
    previous_tools: Mutex<HashMap<String, ToolSnapshot>>,
}

impl Session {
    pub fn new(
        config: Arc<ResponsesConfiguration>,
        connector: Connector,
        execution: execution::ExecutionService,
        authorization: execution::StaticAuthorization,
        headers: HeaderMap,
    ) -> Result<Self, ProtocolError> {
        let forwarded = headers::client(
            &headers,
            &JsonValue::Null,
            &config.client_fingerprint,
            &config.models,
        )?;
        // Retain only the checked metadata used when preparing turns.
        Ok(Self {
            config,
            connector,
            execution,
            authorization,
            forwarded,
            first_attempt: OnceLock::new(),
            previous_tools: Mutex::default(),
        })
    }
}

#[derive(Clone)]
struct ToolSnapshot {
    model: String,
    response_id: String,
}

struct TurnRequest {
    lane: String,
    model: String,
    uses_lite: bool,
}

pub struct TurnAttempt {
    inner: Attempt,
    request: TurnRequest,
}

pub struct Input {
    request: TurnRequest,
    admission: execution::StaticAdmissionRequest,
    usage: UsageConfig<'static>,
    began: Instant,
    encoded_bytes: usize,
}

impl NativeApplication for Session {
    type Input = Input;
    type Attempt = TurnAttempt;
    type Identity = ();

    fn prepare(
        &self,
        request_id: &str,
        lane: &str,
        document: JsonValue,
    ) -> Result<PreparedCreate<Input>, ProtocolError> {
        let began = Instant::now();
        let turn_states = if self.first_attempt.get().is_none() {
            headers::values(&self.forwarded, "x-codex-turn-state")
        } else {
            Vec::new()
        };
        let turn_state =
            protocol::request_turn_state(&turn_states, &[], &document)?.map(str::to_owned);
        let previous = self.previous_tools.lock().unwrap().get(lane).cloned();
        let previous = previous.as_ref().map(|snapshot| protocol::PreviousTools {
            model: &snapshot.model,
            response_id: &snapshot.response_id,
            uses_responses_lite: true,
        });
        let ids = data::image_ids(&self.config);
        let request =
            websocket::parse_create(document, data::image_models(&self.config, &ids), previous)?;
        let turn = TurnRequest {
            lane: lane.to_owned(),
            model: request.model.clone(),
            uses_lite: request.uses_responses_lite,
        };
        let warmup = request.mode == protocol::Mode::Warmup;
        let (admission, usage) = data::prepare_admission(&self.config, &ids, &request, request_id)?;
        let frame = websocket::create_frame(
            request,
            self.connector.contract,
            lane,
            turn_state.as_deref(),
        )?;
        let encoded_bytes = frame.len();
        if encoded_bytes > websocket::WS_ROUTING_BYTES {
            self.connector
                .diagnostics
                .record(SizePath::Native, encoded_bytes);
            return Err(ProtocolError::new(413, "conversation_too_large"));
        }
        Ok(PreparedCreate {
            admission: Input {
                request: turn,
                admission,
                usage,
                began,
                encoded_bytes,
            },
            frame,
            warmup,
        })
    }

    async fn admit(
        &self,
        input: Input,
        _identity: Option<()>,
        _deadline: Instant,
    ) -> Result<Admitted<TurnAttempt, ()>, ProtocolError> {
        let lease = self
            .execution
            .admit_static(&self.authorization, input.admission)
            .await
            .map_err(|error| ResponseError::from(error).protocol)?;
        Ok(Admitted {
            identity: (),
            attempt: TurnAttempt {
                inner: Attempt::new(lease, input.usage, input.began, input.encoded_bytes),
                request: input.request,
            },
        })
    }

    async fn connect(&self, _identity: &(), deadline: Instant) -> Result<Socket, ConnectFailure> {
        self.connector
            .connect(&self.forwarded, deadline)
            .await
            .map(|(socket, _)| socket)
    }

    fn first_response_timeout(&self, attempt: &TurnAttempt) -> Option<std::time::Duration> {
        Some(super::budget(self.config.budget, attempt.inner.images()).first_response)
    }

    fn begin_dispatch(&self, attempt: &mut TurnAttempt) -> Result<(), ProtocolError> {
        attempt.inner.dispatch()?;
        self.first_attempt
            .get_or_init(|| attempt.inner.id().to_owned());
        Ok(())
    }

    async fn record_unadmitted(&self) {
        let Some(first) = self.first_attempt.get() else {
            return;
        };
        let id = || {
            uuid::Uuid::new_v4()
                .hyphenated()
                .to_string()
                .to_ascii_uppercase()
        };
        match self
            .execution
            .record_unadmitted(first.clone(), id(), id())
            .await
        {
            Ok(()) => eprintln!("Upstream WS lifecycle outcome=recorded_unknown"),
            Err(_) => eprintln!("Upstream WS lifecycle outcome=unknown_record_failed"),
        }
    }

    fn evidence(&self, attempt: &TurnAttempt, evidence: NativeEvidence<'_>) {
        match evidence {
            NativeEvidence::Event(event) => attempt.inner.event(event),
            NativeEvidence::PossibleProcessing => attempt.inner.possible_processing(),
        }
    }

    async fn before_output(
        &self,
        attempt: &TurnAttempt,
        document: &JsonValue,
    ) -> Result<(), ProtocolError> {
        attempt.inner.bind(document, false).await
    }

    fn finish(&self, attempt: TurnAttempt, result: NativeFinish) {
        let TurnAttempt {
            inner: mut attempt,
            request,
        } = attempt;
        if matches!(
            result,
            NativeFinish::Terminal {
                client_cancelled: false
            }
        ) && let Some(response_id) = attempt.completed_id()
        {
            let mut tools = self.previous_tools.lock().unwrap();
            if request.uses_lite {
                tools.insert(
                    request.lane,
                    ToolSnapshot {
                        model: request.model,
                        response_id,
                    },
                );
            } else {
                tools.remove(&request.lane);
            }
        }
        match &result {
            NativeFinish::UnprocessedSizeRefusal => self
                .connector
                .diagnostics
                .record(SizePath::Native1009, attempt.encoded_bytes),
            NativeFinish::Indeterminate {
                socket: Some(websocket::SocketEnd::Close(1009)),
                ..
            } => self
                .connector
                .diagnostics
                .record(SizePath::Indeterminate1009, attempt.encoded_bytes),
            _ => {}
        }
        let provider;
        let (failure, source, size_refusal) = match result {
            NativeFinish::Terminal { client_cancelled } => (
                client_cancelled.then_some(Failure::ClientCancelled),
                None,
                false,
            ),
            NativeFinish::Provider {
                failure,
                client_cancelled,
            } => {
                let category = if client_cancelled {
                    Failure::ClientCancelled
                } else {
                    ResponseError::from(failure.protocol).failure()
                };
                provider = failure;
                (Some(category), Some(provider.as_ref()), false)
            }
            NativeFinish::BeforeDispatch { protocol, .. } => {
                (Some(ResponseError::from(protocol).failure()), None, false)
            }
            NativeFinish::UnprocessedSizeRefusal => (Some(Failure::InvalidRequest), None, true),
            NativeFinish::Indeterminate {
                protocol,
                client_cancelled,
                ..
            } => (
                Some(if client_cancelled {
                    Failure::ClientCancelled
                } else {
                    ResponseError::from(protocol).failure()
                }),
                None,
                false,
            ),
        };
        let (lease, outcome) = attempt.finish(failure, source, size_refusal);
        let _ = lease.finish(Some(outcome));
    }
}
