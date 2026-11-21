use std::{sync::Arc, time::Duration};

use bytes::Bytes;
use codexone_config::{
    ImageModel, Model, ResponsesConfiguration, SingleIdentity, UpstreamContract,
};
use codexone_execution as execution;
use codexone_http_upstream as upstream;
use codexone_responses::{self as protocol, JsonValue, ProtocolError};
use http::{HeaderMap, HeaderValue, Method, Request, StatusCode, Uri, header};
use hyper::body::Incoming;
use serde_json::json;
use tokio::time::Instant;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::{
    catalog, headers,
    image_route::NativeImages,
    listener::{DataBodies, ReadError},
    managed::{Affinity, ManagedRoute, Pool},
    reply::{self, FlushDeliveries, Reply},
    response::{self, ResponseError, Transfer},
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
}

impl DataPlane {
    pub fn new(
        config: SingleIdentity,
        token: Option<&str>,
        proxy: Option<upstream::Proxy>,
    ) -> Result<Self, ()> {
        let mut upstream_authorization: Option<HeaderValue> = token
            .map(|token| format!("Bearer {token}").parse())
            .transpose()
            .map_err(|_| ())?;
        if let Some(header) = &mut upstream_authorization {
            header.set_sensitive(true);
        }
        Self::with_upstream(
            config.responses,
            &config.upstream_base_url,
            upstream_authorization,
            config.upstream_contract,
            proxy,
            None,
        )
    }

    pub fn new_pool(
        configuration: ResponsesConfiguration,
        pool: Arc<Pool>,
        (policy_version, pricing_version): (String, String),
        proxy: Option<upstream::Proxy>,
    ) -> Result<Self, ()> {
        let managed = Arc::new(ManagedRoute {
            pool: pool.clone(),
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
        Ok(Self {
            images: Arc::new(NativeImages::new(
                configuration,
                base.parse().map_err(|_| ())?,
                upstream_authorization.as_ref(),
                upstream.clone(),
                managed.clone(),
            )?),
            generation_url: format!("{base}/responses").parse().map_err(|_| ())?,
            compact_url: format!("{base}/responses/compact")
                .parse()
                .map_err(|_| ())?,
            upstream_authorization,
            managed,
            contract: match contract {
                UpstreamContract::Responses => protocol::Contract::Responses,
                UpstreamContract::CodexSubscription => protocol::Contract::CodexSubscription,
            },
            upstream,
            bodies: DataBodies::new(),
        })
    }

    pub fn max_connections(&self) -> usize {
        self.configuration().data_connections.into()
    }

    fn configuration(&self) -> &ResponsesConfiguration {
        self.images.configuration()
    }

    pub async fn handle(
        &self,
        request: Request<Incoming>,
        execution: &execution::ExecutionService,
        pending: FlushDeliveries,
    ) -> Reply {
        let request_id = Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase();
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
        self.route(request, execution, &request_id, pending)
            .await
            .unwrap_or_else(|error| error.reply(&request_id, HeaderMap::new()))
    }

    async fn route(
        &self,
        incoming: Request<Incoming>,
        execution: &execution::ExecutionService,
        request_id: &str,
        pending: FlushDeliveries,
    ) -> Result<Reply, ResponseError> {
        let configuration = self.configuration();
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
                &configuration.models,
            )?;
            let document =
                catalog::document(configuration, incoming.uri(), authorization.as_ref())?;
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
        let (body, body_permit) =
            self.bodies
                .read(incoming)
                .await
                .map_err(|error| match error {
                    ReadError::TooLarge => ProtocolError::new(413, "request_too_large"),
                    ReadError::Timeout => ProtocolError::new(408, "request_body_timeout"),
                    ReadError::Interrupted => ProtocolError::new(400, "invalid_json"),
                    ReadError::Capacity => ProtocolError::new(503, "capacity_exceeded"),
                })?;
        let images = configuration.image_generation.as_ref();
        let image_ids: Vec<_> = images
            .iter()
            .flat_map(|images| &images.models)
            .map(|model| model.id.as_str())
            .collect();
        let image_models = images.map(|images| protocol::ImageModels {
            default_model: &images.default_model,
            allowed_models: &image_ids,
        });
        let request = protocol::Request::parse(
            &body,
            if compact {
                protocol::Mode::Compact
            } else {
                protocol::Mode::Generation
            },
            image_models,
        )?;
        drop(body);
        let model = configuration
            .models
            .iter()
            .find(|model| model.id.nfc().eq(request.model.nfc()))
            .filter(|model| {
                authorization
                    .as_ref()
                    .is_none_or(|key| key.allows_model(&model.id))
            })
            .ok_or(ProtocolError::new(403, "model_not_allowed"))?;
        let effective_images: Vec<_> = image_ids
            .iter()
            .copied()
            .filter(|image| {
                authorization
                    .as_ref()
                    .is_none_or(|key| key.allows_image_model(image))
            })
            .collect();
        let key_efforts = authorization
            .as_ref()
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
                && authorization.as_ref().is_none_or(|key| key.allows_vision()),
            image_generation: model.image_generation == Some(true)
                && authorization.as_ref().is_none_or(|key| key.allows_images()),
            effective_image_models: &effective_images,
            effective_reasoning_efforts: &model_efforts,
            restrict_reasoning_effort: false,
            key_reasoning_efforts: key_efforts.as_deref(),
        }
        .validate(&request)?;
        let stream_compaction = request.stream_compaction;
        if compact && stream_compaction {
            return Err(ProtocolError::new(403, "model_not_allowed").into());
        }
        if request.mode == protocol::Mode::Warmup {
            return Err(ProtocolError::new(400, "unsupported_execution_mode").into());
        }
        let began = Instant::now();
        let admission = execution::StaticAdmissionRequest {
            attempt: Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase(),
            request_id: Some(request_id.to_owned()),
            model: model.id.clone(),
            mode: if request.mode == protocol::Mode::Compact {
                execution::Mode::Compact
            } else {
                execution::Mode::Generation
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
        let client_sse = !compact && request.stream;
        let lite = request.uses_responses_lite;
        let mut request_headers = headers::client(
            &parts.headers,
            request.document(),
            &configuration.client_fingerprint,
            &configuration.models,
        )?;
        let turn_state = if authorization.is_some() {
            protocol::request_turn_state(
                &headers::values(&parts.headers, "x-codex-turn-state"),
                &headers::values(&parts.headers, "connection"),
                request.document(),
            )?
            .map(str::to_owned)
        } else {
            None
        };
        let hints = response::bindings(request.affinity_hints.clone());
        let document = request.into_upstream_document(self.contract, false)?;
        let upstream_sse = !compact && document.get("stream") == Some(&JsonValue::Bool(true));
        let outbound = reply::encode(&document);
        drop(document);
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
        let mut outbound = Request::new(upstream::RequestBody::bytes(outbound));
        *outbound.method_mut() = Method::POST;
        *outbound.uri_mut() = if compact {
            self.compact_url.clone()
        } else {
            self.generation_url.clone()
        };
        let budget = configuration.budget;
        let seconds = |value: u16| Duration::from_secs(value.into());
        let deadline = began + seconds(budget.total_seconds);
        let first_response = if usage.image.is_some() {
            budget.image_first_response_seconds
        } else {
            budget.first_response_seconds
        };
        let limit = if usage.image.is_some() && !upstream_sse {
            protocol::MAX_EVENT_BYTES
        } else {
            protocol::MAX_RESPONSE_BYTES
        };
        let mut options = upstream::ExchangeOptions::new(deadline, seconds(first_response), limit);
        options.response_idle_timeout = Some(seconds(budget.progress_seconds));
        options.upload_idle_timeout = Some(seconds(budget.progress_seconds));
        if upstream_sse {
            options.response_progress = upstream::ResponseProgress::Explicit;
        }
        let (mut lease, turn_owner) =
            if let (Some(managed), Some(key)) = (&self.managed, authorization) {
                let key_id = key.id().to_owned();
                let (lease, upstream_headers) = managed
                    .admit(
                        execution,
                        key,
                        admission,
                        deadline,
                        Some(Affinity {
                            hints: &hints,
                            turn_state: turn_state.as_deref(),
                            headers: &request_headers,
                        }),
                    )
                    .await?;
                let owner = &lease.admission().owner;
                let provider = execution::AccountIdentity {
                    id: owner.identity.clone(),
                    namespace: owner.namespace.clone(),
                };
                request_headers.extend(upstream_headers);
                (lease, Some((&managed.pool, key_id, provider)))
            } else {
                let authorization = static_authorization
                    .as_ref()
                    .ok_or(execution::ExecutionError::Unauthorized)?;
                (
                    execution.admit_static(authorization, admission).await?,
                    None,
                )
            };
        *outbound.headers_mut() = request_headers;
        if Instant::now() >= deadline {
            let error = ResponseError::from(upstream::Error::DeadlineExceeded);
            let _ = lease.finish(Some(execution::Outcome::new(
                Some(execution::Failure::DeadlineExceeded),
                crate::unix_time(),
            )));
            return Err(error);
        }
        lease.begin_dispatch()?;
        let exchange = async {
            let upstream = self.upstream.send(outbound, options).await?;
            if upstream.status() == StatusCode::OK
                && let Some((pool, key, owner)) = &turn_owner
            {
                pool.observe_turn_state(key, owner, upstream.headers());
            }
            Ok(upstream)
        };
        Ok(response::forward(
            exchange,
            Transfer {
                compact,
                client_sse,
                upstream_sse,
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
