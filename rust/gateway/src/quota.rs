use std::{sync::Arc, time::Duration};

use bytes::Bytes;
use codexone_config::{ResponsesConfiguration, UpstreamTransport};
use codexone_execution::{Execution, ExecutionService, Outcome};
use codexone_governance::{Error, Governance, KeyOptions, QuotaCommand, Result};
use codexone_http_upstream::{self as upstream, CancellationToken, HttpUpstream};
use codexone_identity_runtime::IdentityRuntime;
use codexone_quota_jobs::{
    PrimingModel, PrimingRequest, PrimingSettingsUpdate, PrimingSignals, PrimingSupervisor,
    PrimingTransport, PrimingWorker, ResetConsume as ResetConsumeInput, ResetSettingsUpdate,
    ResetSupervisor,
};
use codexone_responses as protocol;
use http::{HeaderMap, HeaderValue, Method, Request, Uri, header};
use serde_json::Value;
use tokio::{task::JoinSet, time::Instant};

use crate::{headers, managed::GovernanceWriter, response, ws};

pub(crate) type Worker = PrimingWorker<GovernanceWriter, ResponsesPriming>;

pub(crate) struct Jobs {
    reset: Arc<ResetSupervisor<GovernanceWriter>>,
    priming: Arc<PrimingSupervisor<GovernanceWriter, ResponsesPriming>>,
    signals: PrimingSignals,
}

impl Jobs {
    pub fn new(
        config: &ResponsesConfiguration,
        key_options: &KeyOptions,
        transport: ResponsesPriming,
        writer: GovernanceWriter,
        governance: Arc<Governance<GovernanceWriter>>,
        identity: IdentityRuntime<GovernanceWriter>,
        execution: ExecutionService,
    ) -> (Arc<Self>, Worker) {
        let models: Vec<_> = config
            .models
            .iter()
            .map(|model| PrimingModel {
                id: model.id.clone(),
                input_micros_per_million: model.input_micros_per_million,
                output_micros_per_million: model.output_micros_per_million,
                reasoning_efforts: key_options
                    .reasoning_efforts
                    .get(&model.id)
                    .cloned()
                    .unwrap_or_default(),
                supports_verbosity: model
                    .upstream
                    .as_ref()
                    .and_then(|value| value.get("support_verbosity"))
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
            })
            .collect();
        let (priming, signals, worker) = PrimingSupervisor::new(
            writer.clone(),
            governance.clone(),
            identity.clone(),
            execution,
            transport,
            config.reserved_micros,
            move || models.clone(),
        );
        let reset = ResetSupervisor::new(writer, governance, identity.clone(), || {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0., |time| time.as_secs_f64())
        });
        let reset_listener = Arc::downgrade(&reset);
        let priming_listener = signals.clone();
        identity.set_observation_listener(move |id, observation| {
            priming_listener.observed_quota(id);
            if observation
                .quota
                .as_ref()
                .and_then(|quota| quota.available_reset_credits)
                .is_some()
                && let Some(reset) = reset_listener.upgrade()
            {
                reset.observed_credits(id);
            }
        });
        (
            Arc::new(Self {
                reset,
                priming,
                signals,
            }),
            worker,
        )
    }

    pub fn spawn(&self, worker: Worker, tasks: &mut JoinSet<Result<()>>) {
        let reset = self.reset.clone();
        tasks.spawn(async move { reset.run().await });
        tasks.spawn(worker.run());
    }

    pub fn stop(&self) {
        self.signals.stop();
        self.reset.stop();
    }

    pub async fn drain(&self) {
        self.reset.shutdown().await;
    }

    pub async fn command(
        &self,
        id: &str,
        command: QuotaCommand,
        body: Option<protocol::JsonValue>,
    ) -> Result<Value> {
        use QuotaCommand::*;
        let payload = match command {
            PrimingStatus => serde_json::to_value(self.priming.status(id).await?),
            PrimingSettings => {
                let (revision, settings) = decode::<PrimingSettingsUpdate>(body)?.settings();
                serde_json::to_value(self.priming.set_settings(id, revision, settings).await?)
            }
            ResetList => serde_json::to_value(self.reset.list_with_status(id).await?),
            ResetStatus => serde_json::to_value(self.reset.status(id).await?),
            ResetSettings => {
                let (revision, settings) = decode::<ResetSettingsUpdate>(body)?.settings()?;
                serde_json::to_value(self.reset.set_settings(id, revision, settings).await?)
            }
            ResetConsume => {
                let command = decode::<ResetConsumeInput>(body)?;
                serde_json::to_value(self.reset.consume(id, command.credit_id).await?)
            }
        };
        payload.map_err(|_| Error::Unavailable)
    }
}

fn decode<T: serde::de::DeserializeOwned>(body: Option<protocol::JsonValue>) -> Result<T> {
    serde_json::from_slice(&body.ok_or(Error::InvalidCommand)?.encode(false))
        .map_err(|_| Error::InvalidCommand)
}

pub(crate) struct ResponsesPriming {
    client: HttpUpstream,
    fingerprint: HeaderMap,
    uri: Uri,
    websocket: Option<ws::Connector>,
    budget: codexone_config::ExecutionBudget,
}

impl ResponsesPriming {
    pub fn new(
        config: &ResponsesConfiguration,
        base: &str,
        proxy: Option<upstream::Proxy>,
    ) -> std::result::Result<Self, ()> {
        let fingerprint = headers::client(
            &HeaderMap::new(),
            &protocol::JsonValue::Null,
            &config.client_fingerprint,
            &config.models,
        )
        .map_err(|_| ())?;
        let client = HttpUpstream::new(proxy);
        let uri: Uri = format!("{base}/responses").parse().map_err(|_| ())?;
        let websocket = (config.upstream_transport == UpstreamTransport::WebSocket)
            .then(|| {
                ws::Connector::new(
                    uri.clone(),
                    client.clone(),
                    protocol::Contract::CodexSubscription,
                    None,
                )
            })
            .transpose()?;
        Ok(Self {
            client,
            fingerprint,
            uri,
            websocket,
            budget: config.budget,
        })
    }
}

impl PrimingTransport for ResponsesPriming {
    async fn exchange(
        &self,
        request: PrimingRequest,
        lease: &mut Execution,
        stop: CancellationToken,
        deadline: Instant,
    ) -> Option<Outcome> {
        let began = Instant::now();
        let transfer = response::Transfer {
            compact: false,
            client_sse: false,
            upstream_sse: true,
            size_fallback: false,
            began,
            usage: protocol::UsageConfig {
                host: protocol::Rates {
                    input_micros_per_million: request.model.input_micros_per_million,
                    output_micros_per_million: request.model.output_micros_per_million,
                },
                image: None,
            },
        };
        let normalized = protocol::Request::parse(
            request.body.to_string().as_bytes(),
            protocol::Mode::Priming,
            None,
        );
        let Ok(normalized) = normalized else {
            return Some(Outcome::new(
                Some(codexone_execution::Failure::InvalidRequest),
                crate::unix_time(),
            ));
        };
        if let Some(socket) = &self.websocket {
            let Ok(frame) = codexone_websocket::native_frame(normalized, socket.contract, "", None)
            else {
                return Some(Outcome::new(
                    Some(codexone_execution::Failure::InvalidRequest),
                    crate::unix_time(),
                ));
            };
            let provider = ws::Provider::with_credentials(request.headers);
            let connect_stop = stop.clone();
            let connect = async {
                socket
                    .connect(&self.fingerprint, &provider, deadline, &connect_stop)
                    .await
                    .map(|(socket, _)| socket)
            };
            return Some(
                ws::discard_priming(
                    connect,
                    frame,
                    lease,
                    transfer,
                    codexone_websocket::BridgeOptions {
                        deadline,
                        budget: ws::budget(self.budget, false),
                        stream: true,
                        continuation: false,
                        cancellation: stop,
                    },
                )
                .await,
            );
        }
        let Ok(normalized) =
            normalized.into_upstream_document(protocol::Contract::CodexSubscription, false)
        else {
            return Some(Outcome::new(
                Some(codexone_execution::Failure::InvalidRequest),
                crate::unix_time(),
            ));
        };
        let mut headers = self.fingerprint.clone();
        headers.extend(request.headers);
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        headers.insert(
            header::ACCEPT,
            HeaderValue::from_static("text/event-stream"),
        );
        let mut outbound = Request::new(upstream::RequestBody::bytes(Bytes::from(
            normalized.encode(false),
        )));
        *outbound.method_mut() = Method::POST;
        *outbound.uri_mut() = self.uri.clone();
        *outbound.headers_mut() = headers;
        let duration = |seconds| Duration::from_secs(u64::from(seconds));
        let mut options = upstream::ExchangeOptions::new(
            deadline,
            duration(self.budget.first_response_seconds),
            protocol::MAX_RESPONSE_BYTES,
        );
        options.cancellation = stop;
        options.response_progress = upstream::ResponseProgress::Explicit;
        options.response_idle_timeout = Some(duration(self.budget.progress_seconds));
        options.upload_idle_timeout = options.response_idle_timeout;
        let outcome =
            response::discard_priming(self.client.send(outbound, options), transfer, lease).await;
        Some(outcome)
    }
}
