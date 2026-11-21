use std::sync::Arc;

use bytes::Bytes;
use codexone_config::{
    ImageModel, Model, ResponsesConfiguration, SingleIdentity, UpstreamContract, UpstreamTransport,
};
use codexone_execution as execution;
use codexone_http_upstream as upstream;
use codexone_responses::{self as protocol, JsonValue, ProtocolError};
use http::{HeaderMap, HeaderValue, Method, Request, StatusCode, Uri, header};
use http_body::Body;
use hyper::body::Incoming;
use serde_json::json;
use tokio::time::Instant;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::{
    body_budget::{BodyPermit, WAIT},
    body_staging::{BodyStaging, StageError, StageReservation, THRESHOLD},
    catalog, headers,
    http_upload::{HttpUploads, Payload},
    image_route::NativeImages,
    listener::{self, DataBodies, ReadError, StagedReadError},
    managed::{Affinity, ManagedRoute, Pool},
    reply::{self, FlushDeliveries, Reply},
    response::{self, ResponseError, Transfer},
    ws,
};

pub struct DataPlane {
    images: Arc<NativeImages>,
    generation_url: Uri,
    compact_url: Uri,
    upstream_authorization: Option<HeaderValue>,
    managed: Option<Arc<ManagedRoute>>,
    contract: protocol::Contract,
    upstream: upstream::HttpUpstream,
    bodies: DataBodies,
    websocket: Option<ws::Connector>,
    uploads: Arc<HttpUploads>,
    staging: Option<BodyStaging>,
    control: crate::control::Control,
}

impl DataPlane {
    pub fn new(
        config: SingleIdentity,
        token: Option<&str>,
        proxy: Option<upstream::Proxy>,
        managed_versions: Option<(String, String)>,
    ) -> Result<Self, ()> {
        let mut upstream_authorization: Option<HeaderValue> = token
            .map(|token| format!("Bearer {token}").parse())
            .transpose()
            .map_err(|_| ())?;
        if let Some(header) = &mut upstream_authorization {
            header.set_sensitive(true);
        }
        let managed = managed_versions.map(|versions| {
            Arc::new(ManagedRoute {
                pool: None,
                versions,
                reserved_micros: config.responses.reserved_micros,
            })
        });
        Self::with_upstream(
            config.responses,
            &config.upstream_base_url,
            upstream_authorization,
            config.upstream_contract,
            proxy,
            managed,
        )
    }

    pub fn new_pool(
        configuration: ResponsesConfiguration,
        pool: Arc<Pool>,
        (policy_version, pricing_version): (String, String),
        proxy: Option<upstream::Proxy>,
    ) -> Result<Self, ()> {
        let managed = Arc::new(ManagedRoute {
            pool: Some(pool.clone()),
            versions: (policy_version, pricing_version),
            reserved_micros: configuration.reserved_micros,
        });
        Self::with_upstream(
            configuration,
            pool.base(),
            None,
            UpstreamContract::CodexSubscription,
            proxy,
            Some(managed),
        )
    }

    fn with_upstream(
        configuration: ResponsesConfiguration,
        base: &str,
        upstream_authorization: Option<HeaderValue>,
        contract: UpstreamContract,
        proxy: Option<upstream::Proxy>,
        managed: Option<Arc<ManagedRoute>>,
    ) -> Result<Self, ()> {
        let upstream = upstream::HttpUpstream::new(proxy);
        let generation_url: Uri = format!("{base}/responses").parse().map_err(|_| ())?;
        let contract = match contract {
            UpstreamContract::Responses => protocol::Contract::Responses,
            UpstreamContract::CodexSubscription => protocol::Contract::CodexSubscription,
        };
        let websocket = (configuration.upstream_transport == UpstreamTransport::WebSocket)
            .then(|| {
                ws::Connector::new(
                    generation_url.clone(),
                    upstream.clone(),
                    contract,
                    upstream_authorization.clone(),
                )
            })
            .transpose()?;
        let control = crate::control::Control::new(base.parse().map_err(|_| ())?);
        Ok(Self {
            images: Arc::new(NativeImages::new(
                configuration,
                base.parse().map_err(|_| ())?,
                upstream_authorization.as_ref(),
                upstream.clone(),
                managed.clone(),
            )?),
            generation_url,
            compact_url: format!("{base}/responses/compact")
                .parse()
                .map_err(|_| ())?,
            upstream_authorization,
            managed,
            contract,
            websocket,
            uploads: Arc::new(HttpUploads::new().map_err(|_| ())?),
            staging: None,
            upstream,
            bodies: DataBodies::new(),
            control,
        })
    }

    pub(crate) fn enable_staging(&mut self, directory: std::path::PathBuf) -> std::io::Result<()> {
        self.staging = Some(BodyStaging::new(directory)?);
        Ok(())
    }

    pub fn max_connections(&self) -> usize {
        self.configuration().data_connections.into()
    }

    fn configuration(&self) -> &ResponsesConfiguration {
        self.images.configuration()
    }

    pub async fn handle(
        &self,
        mut request: Request<Incoming>,
        execution: &execution::ExecutionService,
        pending: FlushDeliveries,
        upgrades: &tokio::sync::mpsc::Sender<ws::Upgrade>,
    ) -> Reply {
        let request_id = Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase();
        if let Some(route) =
            crate::control::Route::recognize(request.method(), request.uri().path())
        {
            return self
                .control
                .handle(
                    route,
                    request,
                    execution,
                    &self.bodies,
                    &self.upstream,
                    self.configuration(),
                    self.upstream_authorization.as_ref(),
                    self.managed
                        .as_ref()
                        .and_then(|managed| managed.pool.as_deref()),
                    &request_id,
                )
                .await;
        }
        if let Some(route) = codexone_images::ImageRoute::from_path(request.uri().path()) {
            return self
                .images
                .handle(
                    route,
                    request,
                    execution,
                    &self.bodies,
                    &request_id,
                    pending,
                )
                .await
                .unwrap_or_else(|error| error.reply(&request_id, HeaderMap::new()));
        }
        let result = async {
            if let Some(connector) = &self.websocket
                && let Some(response) = codexone_websocket::upgrade_response(&request, true)?
            {
                let session = ws::Session::new(
                    self.images.clone(),
                    connector.clone(),
                    execution.clone(),
                    self.managed.clone(),
                    request.headers(),
                )
                .await?;
                let upgrade = ws::Upgrade::new(
                    hyper::upgrade::on(&mut request),
                    session,
                    self.bodies.clone(),
                );
                upgrades
                    .try_send(upgrade)
                    .map_err(|_| ProtocolError::new(503, "capacity_exceeded"))?;
                return Ok(reply::from_bytes(response.map(|()| Bytes::new())));
            }
            self.route(request, execution, &request_id, pending).await
        }
        .await;
        result.unwrap_or_else(|error| error.reply(&request_id, HeaderMap::new()))
    }

    async fn route(
        &self,
        incoming: Request<Incoming>,
        execution: &execution::ExecutionService,
        request_id: &str,
        pending: FlushDeliveries,
    ) -> Result<Reply, ResponseError> {
        let configuration = self.configuration();
        let snapshot = self
            .managed
            .as_ref()
            .and_then(|managed| managed.pool.as_deref())
            .and_then(Pool::directory)
            .map(|directory| directory.snapshot());
        let models = snapshot
            .as_ref()
            .map_or(configuration.models.as_slice(), |directory| {
                &directory.active
            });
        let endpoint = incoming
            .uri()
            .path()
            .strip_prefix("/v1")
            .or_else(|| incoming.uri().path().strip_prefix("/backend-api/codex"));
        let Some(endpoint @ ("/models" | "/responses" | "/responses/compact")) = endpoint else {
            return Err(ProtocolError::new(404, "not_found").into());
        };
        let bearer = headers::values(incoming.headers(), "authorization");
        let (authorization, static_authorization) = if self.managed.is_some() {
            (Some(execution.authenticate(&bearer).await?), None)
        } else {
            (None, Some(execution.authenticate_static(&bearer)?))
        };
        if endpoint == "/models" && incoming.method() == Method::GET {
            headers::client(
                incoming.headers(),
                &JsonValue::Null,
                &configuration.client_fingerprint,
                models,
            )?;
            let document = catalog::document(
                configuration,
                models,
                incoming.uri(),
                authorization.as_ref(),
            )?;
            return Ok(reply::json(
                StatusCode::OK,
                Bytes::from(document.to_string()),
                HeaderMap::new(),
                request_id,
                None,
            ));
        }
        if endpoint == "/models" || incoming.method() != Method::POST {
            return Err(ProtocolError::new(405, "method_not_allowed").into());
        }

        let compact = endpoint == "/responses/compact";
        let (parts, incoming) = incoming.into_parts();
        protocol::validate_request_media_type(
            &headers::values(&parts.headers, "content-type"),
            &headers::values(&parts.headers, "content-encoding"),
        )?;
        let key_id = authorization
            .as_ref()
            .map(execution::AuthenticatedKey::id)
            .or_else(|| {
                static_authorization
                    .as_ref()
                    .map(execution::StaticAuthorization::key_id)
            });
        let staged_length = incoming
            .size_hint()
            .exact()
            .and_then(|length| usize::try_from(length).ok())
            .filter(|length| *length > THRESHOLD);
        let (body, mut body_permit, mut staged) = if let Some(staging) = &self.staging
            && let Some(length) = staged_length
            && !compact
            && !parts.headers.contains_key(header::TRANSFER_ENCODING)
        {
            let staged = listener::read_staged(incoming, staging, length, request_id)
                .await
                .map_err(|error| match error {
                    StagedReadError::Read(error) => bad_read(error),
                    StagedReadError::Stage(error) => bad_stage(error),
                })?;
            let permit = self
                .bodies
                .reserve_http(length, key_id, Instant::now() + WAIT)
                .await
                .map_err(bad_read)?;
            let (bytes, reservation) = staged.decode().await.map_err(bad_stage)?;
            (bytes, permit, Some((staging, reservation)))
        } else {
            let (body, permit) = self
                .bodies
                .read(incoming, key_id, request_id)
                .await
                .map_err(bad_read)?;
            (body, permit, None)
        };
        let image_ids = image_ids(configuration);
        let request = protocol::Request::parse(
            &body,
            if compact {
                protocol::Mode::Compact
            } else {
                protocol::Mode::Generation
            },
            image_models(configuration, &image_ids),
        )?;
        drop(body);
        let stream_compaction = request.stream_compaction;
        if compact && stream_compaction {
            return Err(ProtocolError::new(403, "model_not_allowed").into());
        }
        if request.mode == protocol::Mode::Warmup {
            return Err(ProtocolError::new(400, "unsupported_execution_mode").into());
        }
        let began = Instant::now();
        let (admission, usage) = prepare_admission(
            configuration,
            &image_ids,
            &request,
            request_id,
            authorization.as_ref(),
        )?;
        let client_sse = !compact && request.stream;
        let lite = request.uses_responses_lite;
        let mut request_headers = headers::client(
            &parts.headers,
            request.document(),
            &configuration.client_fingerprint,
            models,
        )?;
        let turn_state = protocol::request_turn_state(
            &headers::values(&parts.headers, "x-codex-turn-state"),
            &headers::values(&parts.headers, "connection"),
            request.document(),
        )?
        .map(str::to_owned);
        let hints = response::bindings(request.affinity_hints.clone());
        let budget = ws::budget(configuration.budget, usage.image.is_some());
        let deadline = began + budget.total;
        let bridge = match self.websocket.as_ref().filter(|_| !compact) {
            Some(connector) => ws::BridgeRequest::prepare(
                connector,
                &parts.headers,
                &mut request_headers,
                &request,
                deadline,
                budget,
            )?,
            None => None,
        };
        // Reject an invalid direct HTTP contract before reserving an execution.
        let mut request = Some(request);
        let direct_payload = if bridge.is_none() {
            let document = request
                .take()
                .expect("direct HTTP request")
                .into_upstream_document(self.contract, false)?;
            let upstream_sse = !compact && document.get("stream") == Some(&JsonValue::Bool(true));
            let payload =
                prepare_http_payload(document, staged.take(), &mut body_permit, deadline).await?;
            Some((upstream_sse, payload))
        } else {
            None
        };
        let (mut lease, provider) =
            if let (Some(managed), Some(key)) = (&self.managed, authorization) {
                let key_id = key.id().to_owned();
                let (lease, upstream_headers) = managed
                    .admit(
                        execution,
                        key,
                        admission,
                        deadline,
                        Some(Affinity {
                            connection: None,
                            hints: &hints,
                            turn_state: turn_state.as_deref(),
                            headers: &request_headers,
                        }),
                    )
                    .await?;
                let provider =
                    ws::Provider::selected(managed.pool.as_ref(), key_id, &lease, upstream_headers);
                (lease, provider)
            } else {
                let authorization = static_authorization
                    .as_ref()
                    .ok_or(execution::ExecutionError::Unauthorized)?;
                (
                    execution.admit_static(authorization, admission).await?,
                    ws::Provider::default(),
                )
            };
        if Instant::now() >= deadline {
            let error = ResponseError::from(upstream::Error::DeadlineExceeded);
            let _ = lease.finish(Some(execution::Outcome::new(
                Some(execution::Failure::DeadlineExceeded),
                crate::unix_time(),
            )));
            return Err(error);
        }
        let (mut body_permit, bridged) = if let Some(bridge) = bridge {
            match ws::forward(
                bridge.authorize(provider.clone()),
                Transfer {
                    compact,
                    client_sse,
                    upstream_sse: true,
                    size_fallback: false,
                    usage,
                    began,
                },
                lease,
                request_id.to_owned(),
                pending.clone(),
                body_permit,
            )
            .await
            {
                ws::BridgeResult::Reply(reply) => return Ok(reply),
                ws::BridgeResult::Fallback(admitted, permit) => {
                    lease = *admitted;
                    (permit, true)
                }
            }
        } else {
            (body_permit, false)
        };

        let (upstream_sse, payload) = if let Some(payload) = direct_payload {
            payload
        } else {
            let encoded = request
                .expect("bridged request")
                .into_upstream_document(self.contract, false);
            let prepared = async {
                let document = encoded?;
                let upstream_sse = document.get("stream") == Some(&JsonValue::Bool(true));
                let payload =
                    prepare_http_payload(document, staged.take(), &mut body_permit, deadline)
                        .await?;
                Ok::<_, ResponseError>((upstream_sse, payload))
            }
            .await;
            match prepared {
                Ok(payload) => payload,
                Err(error) => {
                    // The only route here is a proven unprocessed 1009. Local staging
                    // failure leaves the original admission with explicit zero evidence.
                    let _ = lease.observe(response::evidence(
                        protocol::UsageEvidence::provider_rejection(usage.image.is_some()),
                    ));
                    let _ = lease.finish(Some(execution::Outcome::new(
                        Some(error.failure()),
                        crate::unix_time(),
                    )));
                    return Err(error);
                }
            }
        };
        request_headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        request_headers.insert(
            header::ACCEPT,
            HeaderValue::from_static(if upstream_sse {
                "text/event-stream"
            } else {
                "application/json"
            }),
        );
        if let Some(value) = &self.upstream_authorization {
            request_headers.insert(header::AUTHORIZATION, value.clone());
        }
        if lite {
            request_headers.insert(
                protocol::RESPONSES_LITE_HEADER,
                HeaderValue::from_static("true"),
            );
        }
        request_headers.extend(provider.credentials.clone());
        let mut outbound = Request::new(payload);
        *outbound.method_mut() = Method::POST;
        *outbound.uri_mut() = if compact {
            &self.compact_url
        } else {
            &self.generation_url
        }
        .clone();
        *outbound.headers_mut() = request_headers;

        let limit = if usage.image.is_some() && !upstream_sse {
            protocol::MAX_EVENT_BYTES
        } else {
            protocol::MAX_RESPONSE_BYTES
        };
        let mut options = upstream::ExchangeOptions::new(deadline, budget.first_response, limit);
        options.response_idle_timeout = Some(budget.idle);
        options.upload_idle_timeout = Some(budget.idle);
        if upstream_sse {
            options.response_progress = upstream::ResponseProgress::Explicit;
        }
        if bridged {
            if lease.was_force_stopped() {
                return Err(execution::ExecutionError::AccountForceStopped.into());
            }
            if execution.status() != execution::ExecutionStatus::Accepting {
                let _ = lease.cancel(crate::unix_time());
                return Err(ProtocolError::new(503, "execution_indeterminate").into());
            }
        } else {
            lease.begin_dispatch()?;
        }
        if let Some(stop) = lease.account_stop_token() {
            options.cancellation = stop.clone();
        }
        let zstd_minimum = if !compact && self.contract == protocol::Contract::CodexSubscription {
            configuration.upstream_zstd_minimum_bytes
        } else {
            None
        };
        let exchange = async {
            let upstream = self
                .uploads
                .send(&self.upstream, outbound, options, zstd_minimum)
                .await?;
            if upstream.status() == StatusCode::OK {
                provider.observe_headers(upstream.headers());
            }
            Ok(upstream)
        };
        Ok(response::forward(
            exchange,
            Transfer {
                compact,
                client_sse,
                upstream_sse,
                size_fallback: self.websocket.is_some() && !compact,
                usage,
                began,
            },
            lease,
            request_id.to_owned(),
            pending,
            body_permit,
        )
        .await)
    }
}

async fn prepare_http_payload(
    document: JsonValue,
    stage: Option<(&BodyStaging, StageReservation)>,
    body: &mut BodyPermit,
    deadline: Instant,
) -> Result<Payload, ResponseError> {
    let encoded = reply::encode(&document);
    if let Some((staging, stage)) = stage {
        let file = tokio::time::timeout_at(deadline, staging.rewrite(encoded, stage))
            .await
            .map_err(|_| upstream::Error::DeadlineExceeded)?
            .map_err(bad_stage)?;
        body.release();
        Ok(Payload::Staged(file))
    } else {
        Ok(Payload::Memory(encoded))
    }
}

fn bad_read(error: ReadError) -> ResponseError {
    match error {
        ReadError::TooLarge => ProtocolError::new(413, "request_too_large").into(),
        ReadError::Timeout => ProtocolError::new(408, "request_body_timeout").into(),
        ReadError::Interrupted => ProtocolError::new(400, "invalid_json").into(),
        ReadError::Capacity => ResponseError::body_capacity(),
    }
}

fn bad_stage(error: StageError) -> ResponseError {
    match error {
        StageError::Capacity => ResponseError::body_capacity(),
        StageError::StoragePressure => execution::ExecutionError::StoragePressure.into(),
        StageError::StorageUnavailable => ProtocolError::new(503, "storage_unavailable").into(),
        StageError::InvalidLength => bad_read(ReadError::Interrupted),
    }
}

pub(crate) fn image_ids(configuration: &ResponsesConfiguration) -> Vec<&str> {
    configuration
        .image_generation
        .iter()
        .flat_map(|images| &images.models)
        .map(|model| model.id.as_str())
        .collect()
}

pub(crate) fn image_models<'a>(
    configuration: &'a ResponsesConfiguration,
    ids: &'a [&'a str],
) -> Option<protocol::ImageModels<'a>> {
    configuration
        .image_generation
        .as_ref()
        .map(|images| protocol::ImageModels {
            default_model: &images.default_model,
            allowed_models: ids,
        })
}

pub(crate) fn prepare_admission(
    configuration: &ResponsesConfiguration,
    image_ids: &[&str],
    request: &protocol::Request,
    request_id: &str,
    authorization: Option<&execution::AuthenticatedKey>,
) -> Result<
    (
        execution::StaticAdmissionRequest,
        protocol::UsageConfig<'static>,
    ),
    ProtocolError,
> {
    let model = configuration
        .models
        .iter()
        .find(|model| model.id.nfc().eq(request.model.nfc()))
        .filter(|model| authorization.is_none_or(|key| key.allows_model(&model.id)))
        .ok_or(ProtocolError::new(403, "model_not_allowed"))?;
    let effective_images: Vec<_> = image_ids
        .iter()
        .copied()
        .filter(|image| authorization.is_none_or(|key| key.allows_image_model(image)))
        .collect();
    let key_efforts = authorization
        .and_then(|key| key.reasoning_efforts(&model.id))
        .map(|efforts| efforts.iter().map(String::as_str).collect::<Vec<_>>());
    let model_efforts: Vec<_> = model
        .catalog
        .as_ref()
        .and_then(|catalog| catalog.reasoning_efforts.as_ref())
        .map(|efforts| efforts.iter().map(String::as_str).collect())
        .or_else(|| {
            let levels = model
                .upstream
                .as_ref()?
                .get("supported_reasoning_levels")?
                .as_array()?;
            Some(
                levels
                    .iter()
                    .filter_map(|level| level.get("effort")?.as_str())
                    .collect(),
            )
        })
        .unwrap_or_default();
    protocol::ModelPolicy {
        id: &model.id,
        vision_input: model.vision_input == Some(true)
            && authorization.is_none_or(|key| key.allows_vision()),
        image_generation: model.image_generation == Some(true)
            && authorization.is_none_or(|key| key.allows_images()),
        effective_image_models: &effective_images,
        effective_reasoning_efforts: &model_efforts,
        restrict_reasoning_effort: false,
        key_reasoning_efforts: key_efforts.as_deref(),
    }
    .validate(request)?;
    let images = configuration.image_generation.as_ref();
    let admission = execution::StaticAdmissionRequest {
        attempt: Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase(),
        request_id: Some(request_id.to_owned()),
        model: model.id.clone(),
        mode: match request.mode {
            protocol::Mode::Compact => execution::Mode::Compact,
            protocol::Mode::Warmup => execution::Mode::Warmup,
            protocol::Mode::Generation => execution::Mode::Generation,
            protocol::Mode::Priming => execution::Mode::Priming,
        },
        requirements: execution::Requirements {
            vision_input: request.vision_input,
            image_model: request.image_model.clone(),
            ..Default::default()
        },
        references: response::bindings(request.references.clone()),
        reasoning_effort: request.reasoning_effort.clone(),
        service_tier: request.service_tier.clone(),
    };
    let usage = protocol::UsageConfig {
        host: model_rates(model),
        image: images
            .and_then(|images| {
                images
                    .models
                    .iter()
                    .find(|model| Some(&model.id) == request.image_model.as_ref())
            })
            .map(|model| protocol::ImageUsageConfig {
                rates: image_rates(model),
                expects_svg: request.expects_svg,
                author_rates: &[],
            }),
    };
    Ok((admission, usage))
}

fn model_rates(model: &Model) -> protocol::Rates {
    protocol::Rates {
        input_micros_per_million: model.input_micros_per_million,
        output_micros_per_million: model.output_micros_per_million,
    }
}

fn image_rates(model: &ImageModel) -> protocol::Rates {
    protocol::Rates {
        input_micros_per_million: model.input_micros_per_million,
        output_micros_per_million: model.output_micros_per_million,
    }
}

pub fn unconfigured(method: &Method, path: &str) -> Reply {
    let (status, error) =
        if *method == Method::POST && matches!(path, "/v1/responses" | "/v1/images/generations") {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                json!({"message": "Gateway is not configured.",
            "type": "server_error", "code": "gateway_not_configured"}),
            )
        } else {
            (
                StatusCode::NOT_FOUND,
                json!({"message": "Route not found.",
            "type": "invalid_request_error", "code": "not_found"}),
            )
        };
    reply::from_bytes(
        http::Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(Bytes::from(json!({"error": error}).to_string()))
            .expect("unconfigured response"),
    )
}
