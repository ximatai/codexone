use std::time::Duration;

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
    listener::{DataBodies, ReadError},
    reply::{self, FlushDeliveries, Reply},
    response::{self, ResponseError, Transfer},
};

pub struct DataPlane {
    configuration: ResponsesConfiguration,
    generation_url: Uri,
    compact_url: Uri,
    upstream_authorization: Option<HeaderValue>,
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
        let base = config.upstream_base_url;
        Ok(Self {
            configuration: config.responses,
            generation_url: format!("{base}/responses").parse().map_err(|_| ())?,
            compact_url: format!("{base}/responses/compact")
                .parse()
                .map_err(|_| ())?,
            upstream_authorization,
            contract: match config.upstream_contract {
                UpstreamContract::Responses => protocol::Contract::Responses,
                UpstreamContract::CodexSubscription => protocol::Contract::CodexSubscription,
            },
            upstream: upstream::HttpUpstream::new(proxy),
            bodies: DataBodies::new(),
        })
    }

    pub fn max_connections(&self) -> usize {
        self.configuration.data_connections.into()
    }

    pub async fn handle(
        &self,
        request: Request<Incoming>,
        execution: &execution::ExecutionService,
        pending: FlushDeliveries,
    ) -> Reply {
        let request_id = Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase();
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
        let endpoint = incoming
            .uri()
            .path()
            .strip_prefix("/v1")
            .or_else(|| incoming.uri().path().strip_prefix("/backend-api/codex"));
        let Some(endpoint @ ("/models" | "/responses" | "/responses/compact")) = endpoint else {
            return Err(ProtocolError::new(404, "not_found").into());
        };
        let authorization =
            execution.authenticate_static(&headers::values(incoming.headers(), "authorization"))?;
        if endpoint == "/models" && incoming.method() == Method::GET {
            headers::client(
                incoming.headers(),
                &JsonValue::Null,
                &self.configuration.client_fingerprint,
                &self.configuration.models,
            )?;
            let document = catalog::document(&self.configuration, incoming.uri())?;
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
        let images = self.configuration.image_generation.as_ref();
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
        let model = self
            .configuration
            .models
            .iter()
            .find(|model| model.id.nfc().eq(request.model.nfc()))
            .ok_or(ProtocolError::new(403, "model_not_allowed"))?;
        protocol::ModelPolicy {
            id: &model.id,
            vision_input: model.vision_input == Some(true),
            image_generation: model.image_generation == Some(true),
            effective_image_models: &image_ids,
            effective_reasoning_efforts: &[],
            restrict_reasoning_effort: false,
            key_reasoning_efforts: None,
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
            &self.configuration.client_fingerprint,
            &self.configuration.models,
        )?;
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
        *outbound.headers_mut() = request_headers;

        let budget = self.configuration.budget;
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
        let mut lease = execution.admit_static(&authorization, admission).await?;
        if Instant::now() >= deadline {
            let error = ResponseError::from(upstream::Error::DeadlineExceeded);
            let _ = lease.finish(Some(execution::Outcome::new(
                Some(execution::Failure::DeadlineExceeded),
                crate::unix_time(),
            )));
            return Err(error);
        }
        lease.begin_dispatch()?;
        Ok(response::forward(
            self.upstream.send(outbound, options),
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
