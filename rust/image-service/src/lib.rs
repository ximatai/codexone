//! Durable native Images execution, with a downstream-driven exchange.
mod settlement;
mod static_identity;

use std::{
    fmt,
    future::Future,
    sync::{Arc, OnceLock},
    time::Duration,
};

use codexone_config::{ExecutionBudget, ResponsesConfiguration};
use codexone_execution::{
    Execution, ExecutionError, ExecutionService, Failure, Mode, Outcome, Requirements, Route,
};
use codexone_http_upstream::{Bytes, CancellationToken, ExchangeOptions, HttpUpstream, Instant};
use codexone_images::{
    ImageCapacity, ImageError, ImageEvidence, ImageExchange, ImagePermit, ImageRates, ImageRequest,
    MAX_RESPONSE_BYTES, TokenRates,
};
use http::{HeaderMap, HeaderValue, Method, Request, Uri, header};

pub use codexone_images::{ImageOutput, ImageRoute};
pub use static_identity::StaticImageTarget;

#[derive(Debug)]
pub enum ServiceError {
    Image(ImageError),
    Execution(ExecutionError),
    InvalidConfiguration,
    NotFound,
    Cancelled,
    Deadline,
}

impl fmt::Display for ServiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Image(error) => error.fmt(f),
            Self::Execution(error) => error.fmt(f),
            Self::InvalidConfiguration => f.write_str("invalid image service configuration"),
            Self::NotFound => f.write_str("image route not found"),
            Self::Cancelled => f.write_str("image request cancelled"),
            Self::Deadline => f.write_str("image execution deadline exceeded"),
        }
    }
}

impl std::error::Error for ServiceError {}

impl From<ImageError> for ServiceError {
    fn from(error: ImageError) -> Self {
        Self::Image(error)
    }
}

impl From<ExecutionError> for ServiceError {
    fn from(error: ExecutionError) -> Self {
        Self::Execution(error)
    }
}

pub struct ExchangeContext<'a> {
    /// Gateway-generated, unique durable attempt identifier.
    pub attempt: String,
    /// Gateway-generated public request identifier.
    pub request_id: String,
    /// Output of the shared data-plane fingerprint and metadata policy.
    pub client_metadata: &'a HeaderMap,
    /// Cancelled by downstream disconnect or runtime shutdown.
    pub cancellation: &'a CancellationToken,
}

/// Trusted inputs to the account selection and durable admission performed after capacity.
pub struct ImageAdmission {
    pub attempt: String,
    pub request_id: String,
    pub model: String,
    pub service_tier: Option<String>,
    pub turn_state: Option<HeaderValue>,
    pub deadline: Instant,
    pub cancellation: CancellationToken,
}

impl ImageAdmission {
    pub fn requirements(&self) -> Requirements {
        Requirements {
            route: Route::Images,
            vision_input: false,
            image_model: Some(self.model.clone()),
        }
    }
}

/// One admitted provider attempt. The routing adapter supplies the selected account credential
/// headers from trusted storage. It must check the current Key and account in the transaction.
pub struct ImageDispatch {
    pub execution: Execution,
    pub base: Uri,
    pub account_headers: HeaderMap,
}

/// Instantiate once per data service so every Images request shares the same capacity.
pub struct ImageService<'a> {
    upstream: HttpUpstream,
    capacity: ImageCapacity,
    budget: ExecutionBudget,
    default_model: Option<&'a str>,
    model_ids: Vec<&'a str>,
    render_rates: Vec<(&'a str, TokenRates)>,
    author_rates: Vec<(&'a str, TokenRates)>,
}

impl<'a> ImageService<'a> {
    pub fn new(
        config: &'a ResponsesConfiguration,
        upstream: HttpUpstream,
    ) -> Result<Self, ServiceError> {
        let images = config.image_generation.as_ref();
        let render_rates: Vec<_> = images
            .into_iter()
            .flat_map(|images| &images.models)
            .map(|model| {
                rates(
                    &model.id,
                    model.input_micros_per_million,
                    model.output_micros_per_million,
                )
            })
            .collect::<Result<_, _>>()?;
        let author_rates = config
            .models
            .iter()
            .map(|model| {
                rates(
                    &model.id,
                    model.input_micros_per_million,
                    model.output_micros_per_million,
                )
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            upstream,
            capacity: ImageCapacity::new(config.image_concurrency.into())?,
            budget: config.budget,
            default_model: images.map(|images| images.default_model.as_str()),
            model_ids: render_rates.iter().map(|(id, _)| *id).collect(),
            render_rates,
            author_rates,
        })
    }

    /// Use after ingress bounds have been applied. A pool caller authenticates the Key before
    /// parsing and checks its native Images capability for the selected model before admission.
    pub fn parse(
        &self,
        route: ImageRoute,
        method: &Method,
        headers: &HeaderMap,
        body: Bytes,
        cancellation: &CancellationToken,
    ) -> Result<ImageRequest, ImageError> {
        ImageRequest::parse(
            route,
            method,
            headers,
            body,
            self.default_model,
            &self.model_ids,
            cancellation,
        )
    }

    /// Route and authenticate a bounded static request using the shared durable worker.
    pub async fn start_static(
        &self,
        execution: &ExecutionService,
        target: &StaticImageTarget,
        request: Request<Bytes>,
        context: ExchangeContext<'_>,
    ) -> Result<ImageSession<'_>, ServiceError> {
        let (parts, body) = request.into_parts();
        let route = ImageRoute::from_path(parts.uri.path()).ok_or(ServiceError::NotFound)?;
        let authorization = StaticImageTarget::authenticate(execution, &parts.headers)?;
        let request = self.parse(
            route,
            &parts.method,
            &parts.headers,
            body,
            context.cancellation,
        )?;
        self.start_authorized(request, context, |request| {
            target.admit(execution, &authorization, request)
        })
        .await
    }

    /// Start a parsed, authorized request. In pool mode the closure selects one account and
    /// commits its intent atomically with rechecking the Key's permissions and limits.
    pub async fn start_authorized<F, Fut>(
        &self,
        request: ImageRequest,
        context: ExchangeContext<'_>,
        admit: F,
    ) -> Result<ImageSession<'_>, ServiceError>
    where
        F: FnOnce(ImageAdmission) -> Fut,
        Fut: Future<Output = Result<ImageDispatch, ExecutionError>>,
    {
        let request_id = HeaderValue::from_str(&context.request_id)
            .map_err(|_| ExecutionError::InvalidCommand)?;
        if context.attempt.is_empty()
            || context.attempt.len() > 256
            || context.attempt.contains('\0')
            || request_id.is_empty()
            || request_id.len() > 256
            || request_id.to_str().is_err()
        {
            return Err(ExecutionError::InvalidCommand.into());
        }
        let render = self
            .render_rates
            .iter()
            .find(|(model, _)| *model == request.model())
            .ok_or(ExecutionError::InvalidCommand)?
            .1;

        let cancellation = context.cancellation.child_token();
        let permit = self.capacity.acquire(&cancellation).await?;
        if cancellation.is_cancelled() {
            return Err(ServiceError::Cancelled);
        }
        let started = Instant::now();
        let deadline = started + Duration::from_secs(self.budget.total_seconds.into());
        let admission = ImageAdmission {
            attempt: context.attempt,
            request_id: context.request_id,
            model: request.model().to_owned(),
            service_tier: request.service_tier().map(str::to_owned),
            turn_state: request.turn_state().cloned(),
            deadline,
            cancellation: cancellation.clone(),
        };
        let attempt = admission.attempt.clone();
        let ImageDispatch {
            execution,
            base,
            account_headers,
        } = admit(admission).await?;
        let mut session = ImageSession {
            execution: Some(execution),
            exchange: None,
            evidence: ImageEvidence::default(),
            failure: None,
            request_id,
            started,
            deadline,
            cancellation,
            delivery_abort: Arc::new(OnceLock::new()),
            eof: false,
            _permit: permit,
        };
        if session.cancellation.is_cancelled() {
            session.settle(Some(Failure::ClientCancelled))?;
            return Err(ServiceError::Cancelled);
        }
        if Instant::now() >= deadline {
            session.settle(Some(Failure::DeadlineExceeded))?;
            return Err(ServiceError::Deadline);
        }
        let execution = session
            .execution
            .as_mut()
            .expect("new session owns execution");
        let durable = execution.admission();
        if durable.attempt != attempt
            || durable.request_id.as_deref() != session.request_id.to_str().ok()
            || durable.mode != Some(Mode::Generation)
            || durable.model.as_deref() != Some(request.model())
            || !durable.requirements.as_ref().is_some_and(|requirements| {
                requirements.route == Route::Images
                    && !requirements.vision_input
                    && requirements.image_model.as_deref() == Some(request.model())
            })
        {
            session.settle(Some(Failure::InvalidRequest))?;
            return Err(ExecutionError::InvalidCommand.into());
        }
        if let Err(error) = execution.begin_dispatch() {
            session.settle(Some(if error == ExecutionError::AccountForceStopped {
                Failure::AccountUnavailable
            } else {
                Failure::StorageUnavailable
            }))?;
            return Err(error.into());
        }
        let stop = execution.account_stop_token().cloned();

        let mut options = ExchangeOptions::new(
            deadline,
            Duration::from_secs(self.budget.image_first_response_seconds.into()),
            MAX_RESPONSE_BYTES,
        );
        let progress = Duration::from_secs(self.budget.progress_seconds.into());
        options.upload_idle_timeout = Some(progress);
        options.response_idle_timeout = Some(progress);
        options.cancellation = stop.unwrap_or_else(|| session.cancellation.clone());
        let exchange = ImageExchange::start(
            request,
            &self.upstream,
            &base,
            context.client_metadata,
            &account_headers,
            options,
            ImageRates {
                render,
                authors: &self.author_rates,
            },
        );
        let result = tokio::select! {
            result = exchange => result,
            _ = session.cancellation.cancelled() => {
                session.settle(Some(Failure::ClientCancelled))?;
                return Err(ServiceError::Cancelled);
            }
        };
        match result {
            Ok(exchange) => {
                session.exchange = Some(exchange);
                Ok(session)
            }
            Err(error) => {
                let error = if session.was_force_stopped() {
                    ImageError::force_stopped()
                } else {
                    error
                };
                session.settle_error(&error)?;
                Err(error.into())
            }
        }
    }
}

fn rates(id: &str, input: i64, output: i64) -> Result<(&str, TokenRates), ServiceError> {
    Ok((
        id,
        TokenRates {
            input_micros_per_million: input
                .try_into()
                .map_err(|_| ServiceError::InvalidConfiguration)?,
            output_micros_per_million: output
                .try_into()
                .map_err(|_| ServiceError::InvalidConfiguration)?,
        },
    ))
}

/// Owns the durable lease, the stream and the capacity permit until delivery or cancellation.
#[must_use]
pub struct ImageSession<'a> {
    execution: Option<Execution>,
    exchange: Option<ImageExchange<'a>>,
    evidence: ImageEvidence,
    failure: Option<Outcome>,
    request_id: HeaderValue,
    started: Instant,
    deadline: Instant,
    cancellation: CancellationToken,
    delivery_abort: Arc<OnceLock<DeliveryAbort>>,
    eof: bool,
    _permit: ImagePermit,
}

/// A downstream I/O failure detected before the connection drops the response body.
#[derive(Clone, Copy)]
pub enum DeliveryAbort {
    Disconnected,
    WriteTimeout,
}

impl ImageSession<'_> {
    fn was_force_stopped(&self) -> bool {
        self.execution
            .as_ref()
            .is_some_and(Execution::was_force_stopped)
    }
    pub fn deadline(&self) -> Instant {
        self.deadline
    }

    /// The downstream writer can record the first delivery failure before dropping the session.
    pub fn delivery_abort(&self) -> Arc<OnceLock<DeliveryAbort>> {
        self.delivery_abort.clone()
    }

    /// Safe upstream response headers, including the provider's image request ID on errors.
    pub fn response_headers(&self) -> &HeaderMap {
        self.exchange
            .as_ref()
            .expect("started session")
            .response_headers()
    }

    /// Available for internal account observation before pulling the response body.
    pub fn upstream_head(&self) -> Option<(u16, &HeaderMap)> {
        let exchange = self.exchange.as_ref()?;
        Some((exchange.upstream_status()?, exchange.upstream_headers()?))
    }

    /// Wait for each downstream write to succeed before polling for the next output.
    /// Treat a returned error as terminal and use the adapter's JSON or SSE envelope.
    pub async fn next(&mut self) -> Result<Option<ImageOutput>, ImageError> {
        if self.failure.is_some() || self.eof {
            return Ok(None);
        }
        let stop = self
            .execution
            .as_ref()
            .and_then(Execution::account_stop_token);
        let exchange = self.exchange.as_mut().expect("started session");
        let had_event = exchange.evidence().first_event_at.is_some();
        let result = tokio::select! {
            biased;
            _ = async {
                if let Some(stop) = stop { stop.cancelled().await } else { std::future::pending().await }
            } => Err(ImageError::force_stopped()),
            result = exchange.next() => result,
            _ = self.cancellation.cancelled() => {
                Err(ImageError::cancelled(codexone_images::ExecutionOutcome::Indeterminate))
            }
        };
        if !had_event
            && exchange.evidence().first_event_at.is_some()
            && let Some(execution) = &self.execution
        {
            execution.note_first_event();
        }
        match result {
            Ok(Some(ImageOutput::Begin(mut headers))) => {
                headers.insert("x-request-id", self.request_id.clone());
                headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
                Ok(Some(ImageOutput::Begin(headers)))
            }
            Ok(None) => {
                self.eof = true;
                Ok(None)
            }
            Ok(output) => Ok(output),
            Err(error) => {
                let failure = settlement::failure(&error);
                self.failure = Some(settlement::outcome(
                    Some(failure),
                    Some(&error),
                    exchange.evidence(),
                    self.started,
                ));
                Err(error)
            }
        }
    }

    /// Call after the final downstream write (including an error envelope, if any).
    pub async fn finish(mut self) -> Result<(), ExecutionError> {
        self.close(None).await
    }

    /// Call when the downstream disconnects. Close the upstream and retain its latest evidence.
    pub async fn cancel(mut self) -> Result<(), ExecutionError> {
        self.close(Some(Failure::ClientCancelled)).await
    }

    /// Call when downstream delivery exhausts the execution deadline.
    pub async fn expire(mut self) -> Result<(), ExecutionError> {
        self.close(Some(Failure::DeadlineExceeded)).await
    }

    async fn close(&mut self, failure: Option<Failure>) -> Result<(), ExecutionError> {
        if failure.is_some() || !self.eof {
            self.cancellation.cancel();
        }
        if let Some(exchange) = self.exchange.take() {
            // Retain the last parsed snapshot even if this close future is dropped during cleanup.
            self.evidence = exchange.evidence().clone();
            self.evidence = exchange.close().await;
        }
        self.settle(failure)
    }

    fn settle_error(&mut self, error: &ImageError) -> Result<(), ExecutionError> {
        let failure = settlement::failure(error);
        self.failure = Some(settlement::outcome(
            Some(failure),
            Some(error),
            &self.evidence,
            self.started,
        ));
        self.settle(None)
    }

    fn settle(&mut self, delivery_failure: Option<Failure>) -> Result<(), ExecutionError> {
        let Some(mut execution) = self.execution.take() else {
            return Ok(());
        };
        let evidence = self
            .exchange
            .as_ref()
            .map_or(&self.evidence, ImageExchange::evidence);
        let outcome = self.failure.take().unwrap_or_else(|| {
            let failure = evidence
                .invalid_legacy_result
                .then_some(Failure::InvalidUpstreamResponse)
                .or(delivery_failure)
                .or_else(|| (!self.eof || !evidence.completed).then_some(Failure::Indeterminate));
            settlement::outcome(failure, None, evidence, self.started)
        });
        let observed = evidence
            .usage
            .clone()
            .map_or(Ok(()), |usage| execution.observe(settlement::usage(usage)));
        // Even if the execution layer rejects an evidence snapshot, hand off the outcome.
        let finished = execution.finish(Some(outcome));
        observed.and(finished)
    }
}

impl Drop for ImageSession<'_> {
    fn drop(&mut self) {
        self.cancellation.cancel();
        let failure = match self.delivery_abort.get() {
            Some(DeliveryAbort::Disconnected) => Failure::ClientCancelled,
            Some(DeliveryAbort::WriteTimeout) => Failure::DeadlineExceeded,
            None if Instant::now() >= self.deadline => Failure::DeadlineExceeded,
            None => Failure::ClientCancelled,
        };
        let _ = self.settle(Some(failure));
    }
}
