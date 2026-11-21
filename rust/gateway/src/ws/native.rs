use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

use codexone_execution::{self as execution, Failure};
use codexone_responses::{self as protocol, JsonValue, ProtocolError};
use codexone_websocket::{
    self as websocket, Admitted, CancellationToken, ConnectFailure, NativeApplication,
    NativeEvidence, NativeFinish, NativeOptions, PreparedCreate, Socket,
};
use http::{HeaderMap, HeaderValue, header};
use hyper::upgrade::OnUpgrade;
use hyper_util::rt::TokioIo;
use tokio::time::Instant;

use super::{Connector, Provider, SizePath, attempt::Attempt, ingress::Ingress};
use crate::{
    body_budget::DataBodies,
    data, headers,
    image_route::NativeImages,
    managed::{Affinity, ManagedRoute},
    response::{self, ResponseError},
};

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
            budget: super::budget(self.session.images.configuration().budget, false),
        };
        let socket = websocket::downstream_socket(TokioIo::new(io), self.bodies);
        websocket::serve_native(socket, self.session, options, draining).await;
    }
}

pub struct Session {
    images: Arc<NativeImages>,
    connector: Connector,
    execution: execution::ExecutionService,
    authorization: Authorization,
    forwarded: HeaderMap,
    first_attempt: OnceLock<String>,
    previous_tools: Mutex<HashMap<String, ToolSnapshot>>,
}

enum Authorization {
    Static(execution::StaticAuthorization),
    Managed(Arc<ManagedRoute>, HeaderValue),
}

impl Session {
    pub async fn new(
        images: Arc<NativeImages>,
        connector: Connector,
        execution: execution::ExecutionService,
        managed: Option<Arc<ManagedRoute>>,
        headers: &HeaderMap,
    ) -> Result<Self, ResponseError> {
        let bearer = headers::values(headers, "authorization");
        let authorization = match managed {
            Some(route) => {
                execution.authenticate(&bearer).await?;
                let mut value = headers
                    .get(header::AUTHORIZATION)
                    .expect("authenticated bearer")
                    .clone();
                value.set_sensitive(true);
                Authorization::Managed(route, value)
            }
            None => Authorization::Static(execution.authenticate_static(&bearer)?),
        };
        let config = images.configuration();
        let forwarded = headers::client(
            headers,
            &JsonValue::Null,
            &config.client_fingerprint,
            &config.models,
        )?;
        Ok(Self {
            images,
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
pub struct Identity {
    owner: execution::Owner,
    provider: Provider,
    watch: Option<Arc<execution::AccountConnection>>,
}

impl PartialEq for Identity {
    fn eq(&self, other: &Self) -> bool {
        self.owner == other.owner
    }
}

impl Eq for Identity {}

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
    provider: Provider,
}

pub struct Input {
    request: TurnRequest,
    protocol_request: protocol::Request,
    request_id: String,
    turn_state: Option<String>,
    began: Instant,
    encoded_bytes: usize,
}

impl NativeApplication for Session {
    type Input = Input;
    type Attempt = TurnAttempt;
    type Identity = Identity;

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
        let config = self.images.configuration();
        let ids = data::image_ids(config);
        let request =
            websocket::parse_create(document, data::image_models(config, &ids), previous)?;
        let turn = TurnRequest {
            lane: lane.to_owned(),
            model: request.model.clone(),
            uses_lite: request.uses_responses_lite,
        };
        let warmup = request.mode == protocol::Mode::Warmup;

        let frame = websocket::create_frame(
            request.clone(),
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
                protocol_request: request,
                request_id: request_id.to_owned(),
                turn_state,
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
        identity: Option<Identity>,
        deadline: Instant,
    ) -> Result<Admitted<TurnAttempt, Identity>, ProtocolError> {
        self.admit_turn(input, identity, deadline)
            .await
            .map_err(|error| error.protocol)
    }

    async fn connect(
        &self,
        identity: &Identity,
        deadline: Instant,
    ) -> Result<Socket, ConnectFailure> {
        let stop = self.connection_stop(identity).unwrap_or_default();
        self.connector
            .connect(&self.forwarded, &identity.provider, deadline, &stop)
            .await
            .map(|(socket, _)| socket)
    }

    fn connection_stop(&self, identity: &Identity) -> Option<CancellationToken> {
        identity
            .watch
            .as_ref()
            .map(|watch| watch.stop_token().clone())
    }

    fn first_response_timeout(&self, attempt: &TurnAttempt) -> Option<std::time::Duration> {
        Some(
            super::budget(self.images.configuration().budget, attempt.inner.images())
                .first_response,
        )
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
            NativeEvidence::Event(event) => {
                attempt.provider.observe_event(event);
                attempt.inner.event(event);
            }
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
            ..
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

impl Session {
    async fn admit_turn(
        &self,
        input: Input,
        identity: Option<Identity>,
        deadline: Instant,
    ) -> Result<Admitted<TurnAttempt, Identity>, ResponseError> {
        let config = self.images.configuration();
        let ids = data::image_ids(config);
        let key = match &self.authorization {
            Authorization::Static(_) => None,
            Authorization::Managed(_, bearer) => {
                let key = self
                    .execution
                    .authenticate(&[bearer.to_str().unwrap_or_default()])
                    .await?;
                if let Some(fixed) = &identity
                    && (fixed.owner.key != key.id() || fixed.owner.principal != key.principal())
                {
                    return Err(execution::ExecutionError::Unauthorized.into());
                }
                Some(key)
            }
        };
        let (admission, usage) = data::prepare_admission(
            config,
            &ids,
            &input.protocol_request,
            &input.request_id,
            key.as_ref(),
        )?;
        let (lease, provider) = match (&self.authorization, key) {
            (Authorization::Static(auth), _) => (
                self.execution.admit_static(auth, admission).await?,
                Provider::default(),
            ),
            (Authorization::Managed(route, _), Some(key)) => {
                let key_id = key.id().to_owned();
                let connection = identity.as_ref().map(|fixed| execution::AccountIdentity {
                    id: fixed.owner.identity.clone(),
                    namespace: fixed.owner.namespace.clone(),
                });
                let hints = response::bindings(input.protocol_request.affinity_hints);
                let (lease, credentials) = route
                    .admit(
                        &self.execution,
                        key,
                        admission,
                        deadline,
                        Some(Affinity {
                            connection: connection.as_ref(),
                            hints: &hints,
                            turn_state: input.turn_state.as_deref(),
                            headers: &self.forwarded,
                        }),
                    )
                    .await?;
                let provider = Provider::selected(route.pool.as_ref(), key_id, &lease, credentials);
                (lease, provider)
            }
            _ => return Err(execution::ExecutionError::Unauthorized.into()),
        };
        let watch = match identity {
            Some(fixed) => fixed.watch,
            None => lease.watch_account_connection()?.map(Arc::new),
        };
        let owner = lease.admission().owner.clone();
        Ok(Admitted {
            identity: Identity {
                owner,
                provider: provider.clone(),
                watch,
            },
            attempt: TurnAttempt {
                inner: Attempt::new(lease, usage, input.began, input.encoded_bytes),
                request: input.request,
                provider,
            },
        })
    }
}
