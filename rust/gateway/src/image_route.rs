use std::sync::Arc;

use bytes::Bytes;
use codexone_config::ResponsesConfiguration;
use codexone_execution::{
    AccountIdentity, AuthenticatedKey, ExecutionError, ExecutionService, Mode,
    StaticAdmissionRequest, StaticAuthorization,
};
use codexone_http_upstream::HttpUpstream;
use codexone_image_service::{
    ExchangeContext, ImageAdmission, ImageDispatch, ImageService, ServiceError, StaticImageTarget,
};
use codexone_images::{ImageError, ImageOutput, ImageRoute};
use codexone_responses::{JsonValue, ProtocolError};
use futures_util::StreamExt;
use http::{HeaderMap, HeaderValue, Method, Request, StatusCode, Uri, header};
use http_body::Frame;
use http_body_util::StreamBody;
use hyper::body::Incoming;
use self_cell::self_cell;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    headers,
    listener::{DataBodies, ReadError},
    managed::{Affinity, ManagedRoute},
    reply::{self, FlushDeliveries, Reply},
    response::ResponseError,
};

self_cell! {
    struct ConfiguredImages {
        owner: ResponsesConfiguration,
        #[covariant]
        dependent: ImageService,
    }
}

pub struct NativeImages {
    configured: ConfiguredImages,
    base: Uri,
    account_headers: HeaderMap,
    managed: Option<Arc<ManagedRoute>>,
}

enum Authorization {
    Static(StaticAuthorization),
    Managed(AuthenticatedKey),
}

impl NativeImages {
    pub fn new(
        configuration: ResponsesConfiguration,
        base: Uri,
        authorization: Option<&HeaderValue>,
        upstream: HttpUpstream,
        managed: Option<Arc<ManagedRoute>>,
    ) -> Result<Self, ()> {
        let mut account_headers = HeaderMap::new();
        if let Some(authorization) = authorization {
            account_headers.insert(header::AUTHORIZATION, authorization.clone());
        }
        Ok(Self {
            configured: ConfiguredImages::try_new(configuration, |configuration| {
                ImageService::new(configuration, upstream)
            })
            .map_err(|_| ())?,
            base,
            account_headers,
            managed,
        })
    }

    pub fn configuration(&self) -> &ResponsesConfiguration {
        self.configured.borrow_owner()
    }

    pub async fn handle(
        self: &Arc<Self>,
        route: ImageRoute,
        incoming: Request<Incoming>,
        execution: &ExecutionService,
        bodies: &DataBodies,
        request_id: &str,
        pending: FlushDeliveries,
    ) -> Result<Reply, ResponseError> {
        let authorization = if self.managed.is_some() {
            let bearer = headers::values(incoming.headers(), "authorization");
            Authorization::Managed(execution.authenticate(&bearer).await?)
        } else {
            Authorization::Static(StaticImageTarget::authenticate(
                execution,
                incoming.headers(),
            )?)
        };
        if *incoming.method() != Method::POST {
            return Err(ProtocolError::new(405, "method_not_allowed").into());
        }
        let (parts, incoming) = incoming.into_parts();
        let (body, ingress_permit) = match bodies.read(incoming).await {
            Ok(body) => body,
            Err(ReadError::Capacity) => {
                let mut headers = HeaderMap::new();
                headers.insert(header::RETRY_AFTER, HeaderValue::from_static("1"));
                return Ok(reply::error(
                    ProtocolError::new(503, "capacity_exhausted"),
                    None,
                    request_id,
                    headers,
                ));
            }
            Err(error) => {
                return Err(match error {
                    ReadError::TooLarge => ProtocolError::new(413, "request_too_large"),
                    ReadError::Timeout => ProtocolError::new(408, "request_body_timeout"),
                    ReadError::Interrupted => ProtocolError::new(400, "invalid_request"),
                    ReadError::Capacity => unreachable!(),
                }
                .into());
            }
        };

        let cancellation = CancellationToken::new();
        let request = match self.configured.borrow_dependent().parse(
            route,
            &parts.method,
            &parts.headers,
            body,
            &cancellation,
        ) {
            Ok(request) => request,
            Err(error) => return Ok(image_error(error, HeaderMap::new(), request_id)),
        };
        if let Authorization::Managed(key) = &authorization
            && !key.allows_image_model(request.model())
        {
            return Err(ProtocolError::new(403, "model_not_allowed").into());
        }
        let configuration = self.configuration();
        let client_metadata = headers::client(
            &parts.headers,
            &JsonValue::Null,
            &configuration.client_fingerprint,
            &configuration.models,
        )?;
        let execution = execution.clone();
        let images = self.clone();
        let id = request_id.to_owned();
        let mut output = Box::pin(async_stream::stream! {
            let _ingress_permit = ingress_permit;
            let _cancel_on_drop = cancellation.clone().drop_guard();
            let service = images.configured.borrow_dependent();
            let mut selected = None;
            let result = service
                .start_authorized(
                    request,
                    ExchangeContext {
                        attempt: Uuid::new_v4().hyphenated().to_string().to_ascii_uppercase(),
                        request_id: id.clone(),
                        client_metadata: &client_metadata,
                        cancellation: &cancellation,
                    },
                    |request| async {
                        let dispatch = images.admit(&execution, &authorization, request, &client_metadata).await?;
                        if let Authorization::Managed(key) = &authorization {
                            let owner = &dispatch.execution.admission().owner;
                            selected = Some((key.id(), AccountIdentity {
                                id: owner.identity.clone(),
                                namespace: owner.namespace.clone(),
                            }));
                        }
                        Ok(dispatch)
                    },
                )
                .await;
            let mut session = match result {
                Ok(session) => session,
                Err(error) => {
                    yield Output::Rejected(start_error(error, &id));
                    return;
                }
            };

            let (status, mut headers, mut first_error) = match session.next().await {
                Ok(Some(ImageOutput::Begin(headers))) => (StatusCode::OK, headers, None),
                Err(error) if !error.cancelled => {
                    let (status, headers, bytes) =
                        error_parts(error, session.response_headers().clone(), &id);
                    (status, headers, Some(bytes))
                }
                _ => {
                    let _ = session.cancel().await;
                    return;
                }
            };
            if status == StatusCode::OK
                && let (Some(managed), Some((key, identity))) = (&images.managed, selected)
            {
                managed.pool.observe_turn_state(key, &identity, &headers);
            }
            let streaming = is_sse(&headers);
            if streaming {
                headers.insert("x-accel-buffering", HeaderValue::from_static("no"));
            }
            // A pre-commit upstream timeout gets a JSON error, subject to the write-idle bound.
            let deadline = session.deadline();
            let deadline = Some(deadline).filter(|&deadline| first_error.is_none() || deadline > Instant::now());
            let delivery = pending.limit_image_write(deadline, session.delivery_abort());
            let flushed = delivery.flush_ticket();
            yield Output::Head(status, headers);
            if flushed.await.is_err() {
                let _ = session.cancel().await;
                return;
            }
            loop {
                let (bytes, terminal_error) = match first_error.take() {
                    Some(bytes) => (bytes, true),
                    None => match session.next().await {
                        Ok(Some(ImageOutput::Body(bytes))) => (bytes, false),
                        Ok(None) => break,
                        Err(error) if error.cancelled => {
                            let _ = session.cancel().await;
                            return;
                        }
                        Err(error) if streaming => (Bytes::from(error.sse(&id)), true),
                        Err(_) => break,
                        Ok(Some(ImageOutput::Begin(_))) => unreachable!("Images head was already sent"),
                    },
                };
                if !bytes.is_empty() {
                    let flushed = delivery.flush_ticket();
                    yield Output::Data(bytes);
                    if flushed.await.is_err() {
                        let _ = session.cancel().await;
                        return;
                    }
                }
                if terminal_error {
                    break;
                }
            }
            let _ = session.finish().await;
        });
        match output.next().await {
            Some(Output::Rejected(reply)) => Ok(reply),
            Some(Output::Head(status, headers)) => {
                let frames = output.map(|item| match item {
                    Output::Data(bytes) => Ok(Frame::data(bytes)),
                    _ => unreachable!("Images response head was already sent"),
                });
                Ok(reply::response(
                    status,
                    headers,
                    request_id,
                    Box::pin(StreamBody::new(frames)),
                ))
            }
            None => Err(ProtocolError::new(502, "execution_indeterminate").into()),
            Some(Output::Data(_)) => unreachable!("Images body preceded the head"),
        }
    }

    async fn admit(
        &self,
        execution: &ExecutionService,
        authorization: &Authorization,
        request: ImageAdmission,
        headers: &HeaderMap,
    ) -> Result<ImageDispatch, ExecutionError> {
        let admission = StaticAdmissionRequest {
            requirements: request.requirements(),
            attempt: request.attempt,
            request_id: Some(request.request_id),
            model: request.model,
            mode: Mode::Generation,
            references: Vec::new(),
            reasoning_effort: None,
            service_tier: request.service_tier,
        };
        let (execution, full_headers) = match authorization {
            Authorization::Static(authorization) => (
                execution.admit_static(authorization, admission).await?,
                self.account_headers.clone(),
            ),
            Authorization::Managed(key) => {
                let managed = self.managed.as_ref().ok_or(ExecutionError::Unauthorized)?;
                let turn_state = request
                    .turn_state
                    .as_ref()
                    .and_then(|value| value.to_str().ok());
                managed
                    .admit(
                        execution,
                        key.clone(),
                        admission,
                        request.deadline,
                        Some(Affinity {
                            hints: &[],
                            turn_state,
                            headers,
                        }),
                    )
                    .await?
            }
        };
        Ok(ImageDispatch {
            execution,
            base: self.base.clone(),
            account_headers: full_headers,
        })
    }
}

enum Output {
    Head(StatusCode, HeaderMap),
    Data(Bytes),
    Rejected(Reply),
}

fn is_sse(headers: &HeaderMap) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|media| media.eq_ignore_ascii_case("text/event-stream"))
}

fn error_parts(
    error: ImageError,
    mut headers: HeaderMap,
    request_id: &str,
) -> (StatusCode, HeaderMap, Bytes) {
    if let Some(retry) = error.retry_header().and_then(|value| value.parse().ok()) {
        headers.insert(header::RETRY_AFTER, retry);
    }
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json; charset=utf-8"),
    );
    let status = StatusCode::from_u16(error.status).expect("valid Images status");
    (status, headers, reply::encode(&error.json(request_id)))
}

fn image_error(error: ImageError, headers: HeaderMap, request_id: &str) -> Reply {
    let (status, headers, bytes) = error_parts(error, headers, request_id);
    reply::json(status, bytes, headers, request_id, None)
}

fn start_error(error: ServiceError, request_id: &str) -> Reply {
    let protocol = match error {
        ServiceError::Image(error) => return image_error(error, HeaderMap::new(), request_id),
        ServiceError::Execution(error) => {
            return ResponseError::from(error).reply(request_id, HeaderMap::new());
        }
        ServiceError::Deadline => ProtocolError::new(504, "execution_deadline_exceeded"),
        ServiceError::NotFound => ProtocolError::new(404, "not_found"),
        ServiceError::Cancelled | ServiceError::InvalidConfiguration => {
            ProtocolError::new(503, "execution_indeterminate")
        }
    };
    reply::error(protocol, None, request_id, HeaderMap::new())
}
