use bytes::{Bytes, BytesMut};
use codexone_execution as execution;
use codexone_http_upstream as upstream;
use codexone_responses::{self as protocol, ProtocolError, ProviderFailure};
use futures_util::stream;
use http::{HeaderMap, StatusCode};
use http_body::Frame;
use tokio::time::Instant;

use crate::{
    body_budget::BodyPermit,
    headers,
    reply::{self, Delivery, FlushDeliveries, Reply},
    unix_time,
};

pub struct ResponseError {
    pub protocol: ProtocolError,
    provider: Option<Box<ProviderFailure>>,
    failure: execution::Failure,
    retry_after_seconds: Option<u64>,
}

impl ResponseError {
    pub fn body_capacity() -> Self {
        let mut error = Self::from(ProtocolError::new(503, "capacity_exhausted"));
        error.retry_after_seconds = Some(1);
        error
    }

    pub fn reply(&self, request_id: &str, mut headers: HeaderMap) -> Reply {
        if let Some(seconds) = self.retry_after_seconds {
            headers.insert(http::header::RETRY_AFTER, seconds.into());
        }
        reply::error(self.protocol, self.provider.as_deref(), request_id, headers)
    }

    pub(crate) fn streaming_frame(&self, request_id: &str) -> Bytes {
        let event =
            protocol::stream_error_event(self.protocol, self.provider.as_deref(), request_id);
        Bytes::from(protocol::encode_sse_event(&event).expect("gateway error event type"))
    }
}

impl ResponseError {
    pub(crate) fn failure(&self) -> execution::Failure {
        self.failure
    }
}

impl From<ProtocolError> for ResponseError {
    fn from(error: ProtocolError) -> Self {
        use execution::Failure;
        let failure = match error.code {
            "upstream_authentication_rejected" => Failure::AuthenticationRejected,
            "upstream_rate_limited" => Failure::RateLimited,
            "upstream_unavailable" => Failure::UpstreamUnavailable,
            "upstream_rejected" | "upstream_compact_rejected" => Failure::UpstreamRejected,
            "conversation_too_large" => Failure::InvalidRequest,
            "account_force_stopped" => Failure::AccountUnavailable,
            "execution_deadline_exceeded"
            | "execution_first_response_timeout"
            | "execution_progress_timeout" => Failure::DeadlineExceeded,
            "upstream_response_too_large" | "upstream_event_too_large" => {
                Failure::InvalidUpstreamResponse
            }
            code if code.starts_with("invalid_upstream") => Failure::InvalidUpstreamResponse,
            _ => Failure::Indeterminate,
        };
        Self {
            protocol: error,
            provider: None,
            failure,
            retry_after_seconds: None,
        }
    }
}

impl From<execution::ExecutionError> for ResponseError {
    fn from(error: execution::ExecutionError) -> Self {
        use execution::{ExecutionError, Failure};
        let (status, code, failure) = match error {
            ExecutionError::Unauthorized => (401, "invalid_api_key", Failure::KeyRejected),
            ExecutionError::KeyExpired => (401, "api_key_expired", Failure::KeyRejected),
            ExecutionError::UnknownObject => (
                400,
                "unknown_or_ambiguous_object",
                Failure::ObjectUnavailable,
            ),
            ExecutionError::AmbiguousObject => {
                (400, "unknown_or_ambiguous_object", Failure::ObjectAmbiguous)
            }
            ExecutionError::StoragePressure => {
                (503, "storage_pressure", Failure::StorageUnavailable)
            }
            ExecutionError::MaintenanceRequired => {
                (503, "maintenance_required", Failure::AccountUnavailable)
            }
            ExecutionError::Capacity => (503, "capacity_exceeded", Failure::LocalCapacity),
            ExecutionError::AccountUnavailable | ExecutionError::AccountCooldown { .. } => {
                (503, "account_unavailable", Failure::AccountUnavailable)
            }
            ExecutionError::AccountForceStopped => {
                (503, "account_force_stopped", Failure::AccountUnavailable)
            }
            ExecutionError::ContinuationOwnerUnavailable => (
                503,
                "continuation_owner_unavailable",
                Failure::AccountUnavailable,
            ),
            ExecutionError::DeadlineExceeded => (
                504,
                "execution_deadline_exceeded",
                Failure::DeadlineExceeded,
            ),
            ExecutionError::AccountConcurrency => {
                (429, "account_concurrency_exceeded", Failure::LocalCapacity)
            }
            ExecutionError::KeyLimit => (429, "quota_or_policy_denied", Failure::LocalCapacity),
            ExecutionError::StorageUnavailable | ExecutionError::Database(_) => {
                (503, "execution_indeterminate", Failure::StorageUnavailable)
            }
            _ => (503, "execution_indeterminate", Failure::Indeterminate),
        };
        Self {
            protocol: ProtocolError::new(status, code),
            provider: None,
            failure,
            retry_after_seconds: match error {
                ExecutionError::AccountCooldown {
                    retry_after_seconds,
                } => Some(retry_after_seconds),
                _ => None,
            },
        }
    }
}

impl From<Box<ProviderFailure>> for ResponseError {
    fn from(provider: Box<ProviderFailure>) -> Self {
        let mut result = Self::from(provider.protocol);
        result.provider = Some(provider);
        result
    }
}

impl From<upstream::Error> for ResponseError {
    fn from(error: upstream::Error) -> Self {
        use upstream::Error;
        let (status, code) = match error {
            Error::FirstResponseTimeout => (504, "execution_first_response_timeout"),
            Error::ProgressTimeout => (504, "execution_progress_timeout"),
            Error::DeadlineExceeded => (504, "execution_deadline_exceeded"),
            Error::ProxyAuthenticationRequired => (502, "upstream_proxy_authentication_required"),
            Error::ProxyConnect => (502, "upstream_proxy_failed"),
            Error::ResponseTooLarge => (502, "upstream_response_too_large"),
            _ => (502, "execution_indeterminate"),
        };
        Self::from(ProtocolError::new(status, code))
    }
}

fn binding(object: protocol::ObjectBinding) -> execution::ObjectBinding {
    execution::ObjectBinding {
        kind: object.kind.as_str().to_owned(),
        raw_id: object.raw_id,
    }
}

pub fn bindings(objects: Vec<protocol::ObjectBinding>) -> Vec<execution::ObjectBinding> {
    objects.into_iter().map(binding).collect()
}

pub(crate) fn evidence(usage: protocol::UsageEvidence) -> execution::UsageEvidence {
    execution::UsageEvidence {
        revision: usage.revision.into(),
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cached_tokens: usage.cached_tokens,
        images: usage.images,
        estimated_micros: usage.estimated_micros,
        completeness: match usage.completeness {
            protocol::Completeness::Complete => execution::Completeness::Complete,
            protocol::Completeness::Partial => execution::Completeness::Partial,
        },
        price_completeness: usage.price_completeness.map(|value| match value {
            protocol::PriceCompleteness::Complete => execution::PriceCompleteness::Complete,
            protocol::PriceCompleteness::Partial => execution::PriceCompleteness::Partial,
            protocol::PriceCompleteness::Unavailable => execution::PriceCompleteness::Unavailable,
        }),
        image_input_tokens: usage.image_input_tokens,
        image_output_tokens: usage.image_output_tokens,
        image_input_text_tokens: usage.image_input_text_tokens,
        image_input_image_tokens: usage.image_input_image_tokens,
        svg_input_tokens: usage.svg_input_tokens,
        svg_output_tokens: usage.svg_output_tokens,
        svg_reasoning_tokens: usage.svg_reasoning_tokens,
        svg_author_model: usage.svg_author_model,
        usage_missing_reasons: (!usage.usage_missing_reasons.is_empty()).then(|| {
            usage
                .usage_missing_reasons
                .into_iter()
                .map(str::to_owned)
                .collect()
        }),
        provider_rejected_before_output: usage.provider_rejected_before_output.then_some(true),
        native_images: None,
    }
}

struct Attempt {
    lease: Option<execution::Execution>,
    began: Instant,
    first_event_ms: Option<i64>,
}

impl Attempt {
    fn lease(&mut self) -> &mut execution::Execution {
        self.lease.as_mut().expect("active execution")
    }

    fn note_event(&mut self) {
        self.first_event_ms
            .get_or_insert_with(|| milliseconds(self.began));
    }

    fn check_stopped(&self) -> Result<(), ResponseError> {
        if self
            .lease
            .as_ref()
            .is_some_and(execution::Execution::was_force_stopped)
        {
            Err(execution::ExecutionError::AccountForceStopped.into())
        } else {
            Ok(())
        }
    }

    async fn apply(
        &mut self,
        observation: protocol::Observation,
    ) -> Result<protocol::Delivery, ResponseError> {
        self.note_event();
        for usage in observation.usage {
            self.lease().observe(evidence(usage))?;
        }
        self.check_stopped()?;
        let mut delivery = observation.result.map_err(|error| match error {
            protocol::EventFailure::Protocol(error) => ResponseError::from(error),
            protocol::EventFailure::Provider(error) => ResponseError::from(error),
        })?;
        if !delivery.bindings.is_empty() {
            self.lease()
                .bind(&bindings(std::mem::take(&mut delivery.bindings)))
                .await?;
        }
        self.check_stopped()?;
        Ok(delivery)
    }

    fn outcome(&self, failure: Option<execution::Failure>) -> execution::Outcome {
        let mut outcome = execution::Outcome::new(failure, unix_time());
        outcome.total_milliseconds = Some(milliseconds(self.began));
        outcome.first_event_milliseconds = self.first_event_ms;
        outcome
    }

    fn terminal(&mut self, delivery: &protocol::Delivery) -> Option<Delivery> {
        use execution::{Failure, IncompleteReason};
        let failure = match delivery.terminal {
            None | Some(protocol::Terminal::Completed) => None,
            Some(protocol::Terminal::Failed) => Some(Failure::UpstreamRejected),
            Some(protocol::Terminal::Incomplete(_)) => Some(Failure::Indeterminate),
        };
        let mut outcome = self.outcome(failure);
        outcome.actual_service_tier = delivery.actual_service_tier.clone();
        if let Some(protocol::Terminal::Incomplete(reason)) = delivery.terminal {
            outcome.upstream_incomplete_reason = Some(match reason {
                protocol::IncompleteReason::MaxOutputTokens => IncompleteReason::MaxOutputTokens,
                protocol::IncompleteReason::MaxMessages => IncompleteReason::MaxMessages,
                protocol::IncompleteReason::ContentFilter => IncompleteReason::ContentFilter,
                protocol::IncompleteReason::Steered => IncompleteReason::Steered,
                protocol::IncompleteReason::Unspecified => IncompleteReason::Unspecified,
            });
        }
        let lease = self.lease.take().expect("active execution");
        if failure.is_some() {
            let _ = lease.finish(Some(outcome));
            None
        } else {
            Some(Delivery::new(lease, outcome))
        }
    }

    fn fail(&mut self, error: &ResponseError) {
        let mut outcome = self.outcome(Some(error.failure));
        outcome.cooldown_seconds = error
            .provider
            .as_ref()
            .filter(|_| {
                matches!(
                    error.failure,
                    execution::Failure::RateLimited | execution::Failure::UpstreamUnavailable
                )
            })
            .and_then(|provider| provider.account_cooldown(outcome.at_unix_seconds));
        if let Some(lease) = self.lease.take() {
            let _ = lease.finish(Some(outcome));
        }
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        if let Some(lease) = self.lease.take() {
            let _ = lease.finish(Some(
                self.outcome(Some(execution::Failure::ClientCancelled)),
            ));
        }
    }
}

pub(crate) fn milliseconds(start: Instant) -> i64 {
    start.elapsed().as_millis().min(i64::MAX as u128) as i64
}

pub struct Transfer {
    pub compact: bool,
    pub client_sse: bool,
    pub upstream_sse: bool,
    pub size_fallback: bool,
    pub usage: protocol::UsageConfig<'static>,
    pub began: Instant,
}

pub async fn forward(
    exchange: impl std::future::Future<Output = Result<upstream::Response, upstream::Error>>,
    transfer: Transfer,
    lease: execution::Execution,
    request_id: String,
    pending: FlushDeliveries,
    body_permit: BodyPermit,
) -> Reply {
    let mut attempt = Attempt {
        lease: Some(lease),
        began: transfer.began,
        first_event_ms: None,
    };
    let mut response_headers = HeaderMap::new();
    let result = async {
        let upstream = exchange.await?;
        let status = upstream.status();
        response_headers = headers::provider(
            upstream.headers(),
            status == StatusCode::OK && !transfer.compact,
        );
        if status != StatusCode::OK {
            let error = refusal(upstream, transfer.compact).await;
            if let Some(usage) = error.http_rejection_usage(transfer.usage.image.is_some()) {
                attempt.lease().observe(evidence(usage))?;
            }
            if transfer.size_fallback && status == StatusCode::PAYLOAD_TOO_LARGE {
                return Err(ProtocolError::new(413, "conversation_too_large").into());
            }
            return Err(ResponseError::from(Box::new(error)));
        }

        let content_type = upstream
            .headers()
            .get(http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok());
        protocol::validate_upstream_media_type(content_type, transfer.upstream_sse)?;
        if transfer.upstream_sse {
            let mut reader = EventReader::new(upstream, &transfer, Some(body_permit));
            loop {
                let Some(delivery) = reader
                    .next(&mut attempt, Some(&mut response_headers))
                    .await?
                else {
                    return Err(ProtocolError::new(502, "execution_indeterminate").into());
                };
                if transfer.client_sse
                    && let Some(document) = &delivery.document
                {
                    let frame = Bytes::from(protocol::encode_sse_event(document)?);
                    let completion = delivery
                        .terminal
                        .is_some()
                        .then(|| attempt.terminal(&delivery))
                        .flatten();
                    let terminal = delivery.terminal.is_some();
                    let stream = StreamOutput {
                        reader: Some(reader),
                        attempt: Attempt {
                            lease: attempt.lease.take(),
                            ..attempt
                        },
                        first: Some((frame, completion)),
                        done: terminal,
                        request_id: request_id.clone(),
                        pending,
                    };
                    return Ok(reply::sse(
                        response_headers.clone(),
                        &request_id,
                        stream.frames(),
                    ));
                }
                if delivery.terminal.is_some() {
                    return json_delivery(
                        &mut attempt,
                        delivery,
                        response_headers.clone(),
                        &request_id,
                        pending,
                    );
                }
            }
        } else {
            let bytes = upstream.collect().await?;
            drop(body_permit);
            let delivery = attempt
                .apply(protocol::observe_json(
                    &bytes,
                    transfer.usage,
                    transfer.compact,
                ))
                .await?;
            json_delivery(
                &mut attempt,
                delivery,
                response_headers.clone(),
                &request_id,
                pending,
            )
        }
    }
    .await;
    match result {
        Ok(reply) => reply,
        Err(error) => {
            let error = attempt.check_stopped().err().unwrap_or(error);
            attempt.fail(&error);
            error.reply(&request_id, response_headers)
        }
    }
}

/// Observe the same protocol and usage records as a client stream, discarding its text.
pub(crate) async fn discard_priming(
    exchange: impl std::future::Future<Output = Result<upstream::Response, upstream::Error>>,
    transfer: Transfer,
    lease: &mut execution::Execution,
) -> execution::Outcome {
    let mut first_event = None;
    let result = async {
        let upstream = exchange.await?;
        if upstream.status() != StatusCode::OK {
            let error = refusal(upstream, false).await;
            if let Some(usage) = error.http_rejection_usage(false) {
                lease.observe(evidence(usage))?;
            }
            return Err(ResponseError::from(Box::new(error)));
        }
        let media = upstream
            .headers()
            .get(http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok());
        if let Err(error) = protocol::validate_upstream_media_type(media, true) {
            upstream.close().await;
            return Err(error.into());
        }
        let mut reader = EventReader::new(upstream, &transfer, None);
        let result = async {
            while let Some(observation) = reader.next_observation().await? {
                first_event.get_or_insert_with(|| milliseconds(transfer.began));
                for usage in observation.usage {
                    lease.observe(evidence(usage))?;
                }
                let delivery = observation.result.map_err(|error| match error {
                    protocol::EventFailure::Protocol(error) => ResponseError::from(error),
                    protocol::EventFailure::Provider(error) => ResponseError::from(error),
                })?;
                reader.mark_progress(delivery.progress)?;
                if let Some(terminal) = delivery.terminal {
                    let failure = match terminal {
                        protocol::Terminal::Completed => None,
                        protocol::Terminal::Failed => Some(execution::Failure::UpstreamRejected),
                        protocol::Terminal::Incomplete(_) => {
                            Some(execution::Failure::Indeterminate)
                        }
                    };
                    let mut outcome = execution::Outcome::new(failure, unix_time());
                    outcome.actual_service_tier = delivery.actual_service_tier;
                    return Ok(outcome);
                }
            }
            Err(ProtocolError::new(502, "execution_indeterminate").into())
        }
        .await;
        reader.upstream.close().await;
        result
    }
    .await;
    let mut outcome = result.unwrap_or_else(|error: ResponseError| {
        let mut outcome = execution::Outcome::new(Some(error.failure), unix_time());
        outcome.cooldown_seconds = error
            .provider
            .as_ref()
            .filter(|_| {
                matches!(
                    error.failure,
                    execution::Failure::RateLimited | execution::Failure::UpstreamUnavailable
                )
            })
            .and_then(|provider| provider.account_cooldown(outcome.at_unix_seconds));
        outcome
    });
    outcome.total_milliseconds = Some(milliseconds(transfer.began));
    outcome.first_event_milliseconds = first_event;
    outcome
}

fn json_delivery(
    attempt: &mut Attempt,
    delivery: protocol::Delivery,
    headers: HeaderMap,
    request_id: &str,
    pending: FlushDeliveries,
) -> Result<Reply, ResponseError> {
    let document = delivery
        .document
        .as_ref()
        .ok_or(ProtocolError::new(502, "invalid_upstream_response"))?;
    let completion = attempt.terminal(&delivery);
    Ok(reply::json(
        StatusCode::OK,
        reply::encode(document),
        headers,
        request_id,
        completion.map(|value| (value, pending)),
    ))
}

async fn refusal(mut upstream: upstream::Response, compact: bool) -> ProviderFailure {
    let status = upstream.status().as_u16();
    let headers = upstream.headers().clone();
    let mut body = BytesMut::new();
    let mut complete = true;
    loop {
        match upstream.next_chunk().await {
            Ok(Some(chunk)) if body.len() + chunk.len() <= 65_536 => body.extend_from_slice(&chunk),
            Ok(None) => break,
            _ => {
                complete = false;
                break;
            }
        }
    }
    upstream.close().await;
    protocol::http_provider_failure(
        status,
        complete.then_some(&body),
        &headers::values(&headers, "retry-after"),
        &headers::values(&headers, "connection"),
        compact,
    )
}

struct EventReader {
    upstream: upstream::Response,
    chunk: Bytes,
    parser: protocol::ResponseStream<'static>,
    effective_progress: bool,
    returned_turn_state: bool,
    _body_permit: Option<BodyPermit>,
}

impl EventReader {
    fn new(
        upstream: upstream::Response,
        transfer: &Transfer,
        body_permit: Option<BodyPermit>,
    ) -> Self {
        Self {
            upstream,
            chunk: Bytes::new(),
            parser: protocol::ResponseStream::new(transfer.client_sse, transfer.usage),
            effective_progress: false,
            returned_turn_state: false,
            _body_permit: body_permit,
        }
    }

    async fn next(
        &mut self,
        attempt: &mut Attempt,
        mut response_headers: Option<&mut HeaderMap>,
    ) -> Result<Option<protocol::Delivery>, ResponseError> {
        let Some(observation) = self.next_observation().await? else {
            return Ok(None);
        };
        if !self.returned_turn_state
            && let Some(state) = observation.turn_state.as_deref()
        {
            self.returned_turn_state = true;
            if let Some(headers) = response_headers.as_mut()
                && let Ok(header) = state.parse()
            {
                headers.insert("x-codex-turn-state", header);
            }
        }
        let delivery = attempt.apply(observation).await?;
        self.mark_progress(delivery.progress)?;
        Ok(Some(delivery))
    }

    async fn next_observation(&mut self) -> Result<Option<protocol::Observation>, ResponseError> {
        loop {
            if self.chunk.is_empty() {
                let Some(chunk) = self.upstream.next_chunk().await? else {
                    self.parser.finish()?;
                    return Ok(None);
                };
                self.chunk = chunk;
            }
            let mut rest = self.chunk.as_ref();
            let observation = self.parser.next_event(&mut rest)?;
            self.chunk = self.chunk.slice(self.chunk.len() - rest.len()..);
            let Some(observation) = observation else {
                continue;
            };
            return Ok(Some(observation));
        }
    }

    fn mark_progress(&mut self, progress: protocol::Progress) -> Result<(), ResponseError> {
        if progress == protocol::Progress::Activity
            || (!self.effective_progress && progress == protocol::Progress::Acknowledgement)
        {
            self.upstream.mark_response_progress()?;
            self.effective_progress = true;
        }
        Ok(())
    }
}

struct StreamOutput {
    reader: Option<EventReader>,
    attempt: Attempt,
    first: Option<(Bytes, Option<Delivery>)>,
    done: bool,
    request_id: String,
    pending: FlushDeliveries,
}

impl StreamOutput {
    fn frames(
        self,
    ) -> impl futures_util::Stream<Item = Result<Frame<Bytes>, std::convert::Infallible>> {
        stream::unfold(self, |mut output| async {
            let data = output.frame().await?;
            Some((Ok(Frame::data(data)), output))
        })
    }

    async fn frame(&mut self) -> Option<Bytes> {
        if let Some((frame, completion)) = self.first.take() {
            if let Some(completion) = completion {
                self.pending.enqueue(completion);
            }
            return Some(frame);
        }
        if self.done {
            self.done = false;
            self.reader.take();
            // Keep the completed event's submission independent of the trailing marker.
            self.pending.wait().await;
            return Some(Bytes::from_static(protocol::DONE_FRAME));
        }
        let reader = self.reader.as_mut()?;
        loop {
            let next = async {
                let delivery = reader
                    .next(&mut self.attempt, None)
                    .await?
                    .ok_or(ProtocolError::new(502, "execution_indeterminate"))?;
                let frame = delivery
                    .document
                    .as_ref()
                    .map(protocol::encode_sse_event)
                    .transpose()?
                    .map(Bytes::from);
                Ok::<_, ResponseError>((delivery, frame))
            }
            .await;
            match next {
                Ok((delivery, Some(frame))) => {
                    if delivery.terminal.is_some() {
                        if let Some(completion) = self.attempt.terminal(&delivery) {
                            self.pending.enqueue(completion);
                        }
                        self.done = true;
                    }
                    return Some(frame);
                }
                Ok((_, None)) => continue,
                Err(error) => {
                    self.reader.take();
                    let error = self.attempt.check_stopped().err().unwrap_or(error);
                    self.attempt.fail(&error);
                    return Some(error.streaming_frame(&self.request_id));
                }
            }
        }
    }
}
