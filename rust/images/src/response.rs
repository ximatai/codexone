use std::{borrow::Cow, collections::HashSet, vec};

use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_http_upstream::{
    Bytes, CancellationToken, ExchangeOptions, HttpUpstream, Instant, Response, ResponseProgress,
};
use codexone_wire::{JsonObject, JsonValue, SseDecoder, SsePayload};
use http::{HeaderMap, HeaderValue, Uri, header};
use sha2::{Digest, Sha256};
use unicode_normalization::{UnicodeNormalization, is_nfc};

use crate::{
    ExecutionOutcome, ImageEndpoint, ImageError, ImageEvidence, ImageRates, ImageRequest,
    connection_names,
    payload::canonical_base64,
    request::RequiredFormat,
    usage::{AuthorEvidence, Counters, Pricing, StreamUsage},
    valid_turn_state,
};

pub const MAX_RESPONSE_BYTES: usize = 48 * 1024 * 1024;
const MAX_ERROR_BYTES: usize = 64 * 1024;

pub enum ImageOutput {
    /// Safe response headers. Add the gateway's x-request-id and cache-control when committing.
    Begin(HeaderMap),
    Body(Bytes),
}

/// A downstream-driven, single-attempt exchange. Read one output at a time and apply downstream
/// backpressure before pulling again. Cancel the provided token on disconnect and use close()
/// to join the upstream and retrieve the last evidence. Calling next() after an error is terminal.
pub struct ImageExchange<'a> {
    upstream: Option<Response>,
    headers: HeaderMap,
    state: State,
    user_streaming: bool,
    endpoint: ImageEndpoint,
    format: Option<RequiredFormat>,
    pricing: Pricing<'a>,
    evidence: ImageEvidence,
    deadlines: OutputDeadline,
}

struct OutputDeadline {
    deadline: Instant,
    cancel: CancellationToken,
}

impl OutputDeadline {
    fn check(&self, outcome: ExecutionOutcome) -> Result<(), ImageError> {
        if self.cancel.is_cancelled() {
            return Err(ImageError::cancelled(outcome));
        }
        if Instant::now() >= self.deadline {
            return Err(ImageError::new(504, "execution_deadline_exceeded", outcome));
        }
        Ok(())
    }
}

enum State {
    Reject,
    UnexpectedMedia,
    Json,
    Sse(Box<SseExchange>),
    Buffered(Bytes),
    Converted(Box<Converted>),
    End,
}

struct SseExchange {
    decoder: SseDecoder,
    pending: Bytes,
    usage: StreamUsage,
    seen: HashSet<CompletionId>,
    aggregated: Option<JsonObject>,
    begin_sent: bool,
}

#[derive(Hash, Eq, PartialEq)]
enum CompletionId {
    Index([u8; 32]),
    Content([u8; 32]),
}

struct Converted {
    fields: JsonObject,
    items: std::iter::Peekable<vec::IntoIter<JsonValue>>,
    created: JsonValue,
}

impl<'a> ImageExchange<'a> {
    /// Dispatch after durable admission using the selected account. The supplied execution
    /// deadline includes upload. The transport starts its first-response timer after upload.
    pub async fn start(
        request: ImageRequest,
        upstream: &HttpUpstream,
        base: &Uri,
        client_metadata: &HeaderMap,
        account_headers: &HeaderMap,
        mut options: ExchangeOptions,
        rates: ImageRates<'a>,
    ) -> Result<Self, ImageError> {
        let deadlines = OutputDeadline {
            deadline: options.deadline,
            cancel: options.cancellation.clone(),
        };
        deadlines.check(ExecutionOutcome::NotDispatched)?;
        let outgoing = request.upstream_request(base, client_metadata, account_headers)?;
        let endpoint = request.endpoint;
        let format = request.format;
        let user_streaming = request.streaming;
        let aggregate_sse = request.aggregate_sse;
        // Release the request's encoded body reference. The connection owns the upload now.
        drop(request);

        // This adapter applies separate byte caps for SSE, JSON and provider errors. The
        // decoder must see the valid prefix of a chunk even if that chunk crosses the cap.
        options.max_response_bytes = usize::MAX;
        options.response_progress = ResponseProgress::Explicit;
        let response = upstream
            .send(outgoing, options)
            .await
            .map_err(|error| ImageError::transport(error, true))?;
        let headers = safe_headers(response.headers());
        let media = media_type(&headers);
        let status = response.status().as_u16();
        let mut evidence = ImageEvidence::default();
        if (400..=499).contains(&status) {
            evidence.record_rejection();
        }
        let state = if status != 200 {
            State::Reject
        } else if user_streaming && media.eq_ignore_ascii_case("application/json") {
            State::Json
        } else if media.eq_ignore_ascii_case("text/event-stream")
            && (user_streaming || aggregate_sse)
        {
            let raw_media = headers
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.split(';').next())
                .unwrap_or("");
            if !raw_media.eq_ignore_ascii_case("text/event-stream") {
                State::UnexpectedMedia
            } else {
                State::Sse(Box::new(SseExchange {
                    decoder: SseDecoder::new(MAX_RESPONSE_BYTES, MAX_RESPONSE_BYTES),
                    pending: Bytes::new(),
                    usage: StreamUsage::default(),
                    seen: HashSet::new(),
                    aggregated: None,
                    begin_sent: false,
                }))
            }
        } else if user_streaming {
            State::UnexpectedMedia
        } else {
            State::Json
        };
        Ok(Self {
            upstream: Some(response),
            headers,
            state,
            user_streaming,
            endpoint,
            format,
            pricing: Pricing {
                rates,
                expects_svg: format == Some(RequiredFormat::Svg),
            },
            evidence,
            deadlines,
        })
    }

    /// Safe response headers available even when the body later fails. The normal success
    /// headers are supplied by Begin, which accounts for response conversion.
    pub fn response_headers(&self) -> &HeaderMap {
        &self.headers
    }

    /// For internal account health and quota observations only.
    pub fn upstream_headers(&self) -> Option<&HeaderMap> {
        self.upstream.as_ref().map(Response::headers)
    }

    pub fn upstream_status(&self) -> Option<u16> {
        self.upstream
            .as_ref()
            .map(|response| response.status().as_u16())
    }

    pub fn evidence(&self) -> &ImageEvidence {
        &self.evidence
    }

    pub async fn close(mut self) -> ImageEvidence {
        self.stop().await;
        self.evidence
    }

    pub async fn next(&mut self) -> Result<Option<ImageOutput>, ImageError> {
        let result = self.read_next().await;
        let result = match result {
            Ok(Some(output)) => self
                .deadlines
                .check(ExecutionOutcome::Indeterminate)
                .map(|()| Some(output)),
            result => result,
        };
        if result.is_err() {
            self.stop().await;
        }
        result
    }

    async fn stop(&mut self) {
        if let State::Sse(stream) = &mut self.state
            && let Some(usage) = stream.usage.finish(&self.pricing)
        {
            self.evidence.usage = Some(usage);
        }
        self.state = State::End;
        if let Some(upstream) = self.upstream.take() {
            upstream.close().await;
        }
    }

    async fn read_next(&mut self) -> Result<Option<ImageOutput>, ImageError> {
        if matches!(self.state, State::End) {
            return Ok(None);
        }
        if !matches!(self.state, State::Reject) {
            self.deadlines.check(ExecutionOutcome::Indeterminate)?;
        }

        let begin = match &mut self.state {
            State::Reject => {
                let upstream = self.upstream.as_mut().expect("the response is still open");
                let oversized = upstream
                    .headers()
                    .get(header::CONTENT_LENGTH)
                    .and_then(|length| length.to_str().ok())
                    .and_then(|length| length.parse::<u64>().ok())
                    .is_some_and(|length| length > MAX_ERROR_BYTES as u64);
                let body = if oversized {
                    None
                } else {
                    collect(upstream, MAX_ERROR_BYTES, false).await.ok()
                };
                let document = body.and_then(|body| JsonValue::decode(&body).ok());
                let error = ImageError::http(
                    upstream.status().as_u16(),
                    upstream.headers(),
                    document.as_ref(),
                );
                return Err(error);
            }
            State::UnexpectedMedia => {
                return Err(ImageError::indeterminate("invalid_upstream_content_type"));
            }
            State::Json => self.read_json().await?,
            State::Sse(stream) => {
                if self.user_streaming && !stream.begin_sent {
                    stream.begin_sent = true;
                    return Ok(Some(ImageOutput::Begin(self.headers.clone())));
                }
                let upstream = self.upstream.as_mut().expect("the response is still open");
                let config = StreamConfig {
                    streaming: self.user_streaming,
                    endpoint: self.endpoint,
                    pricing: &self.pricing,
                };
                if let Some(bytes) = stream.next(upstream, config, &mut self.evidence).await? {
                    return Ok(Some(ImageOutput::Body(bytes)));
                }
                self.evidence.usage = stream.usage.finish(&self.pricing);
                self.evidence.completed = true;
                self.upstream = None;
                if self.user_streaming {
                    self.state = State::End;
                    return Ok(None);
                }
                let mut result = stream
                    .aggregated
                    .take()
                    .expect("non-streaming completion is assembled");
                if let Some(usage) = stream.usage.take_render() {
                    result.insert("usage", usage);
                }
                let bytes = JsonValue::Object(result).encode(true).into();
                self.state = State::Buffered(bytes);
                Some("application/json")
            }
            State::Buffered(_) => {
                let State::Buffered(bytes) = std::mem::replace(&mut self.state, State::End) else {
                    unreachable!()
                };
                return Ok(Some(ImageOutput::Body(bytes)));
            }
            State::Converted(conversion) => {
                let Some(item) = conversion.items.next() else {
                    self.state = State::End;
                    return Ok(Some(ImageOutput::Body(Bytes::from_static(
                        b"data: [DONE]\n\n",
                    ))));
                };
                let last = conversion.items.peek().is_none();
                return Ok(Some(ImageOutput::Body(conversion.event(
                    item,
                    last,
                    self.endpoint,
                ))));
            }
            State::End => unreachable!(),
        };
        let mut headers = self.headers.clone();
        if let Some(media) = begin {
            headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(media));
        }
        Ok(Some(ImageOutput::Begin(headers)))
    }

    async fn read_json(&mut self) -> Result<Option<&'static str>, ImageError> {
        let response = self.upstream.as_mut().expect("the response is still open");
        let body = collect(response, MAX_RESPONSE_BYTES, true).await?;
        self.upstream = None;
        let document = JsonValue::decode(&body).ok();
        let strict = self.user_streaming
            || self.endpoint == ImageEndpoint::Generation
            || self.format.is_some();
        if document.is_some() || !self.user_streaming {
            self.evidence.first_event_at = Some(Instant::now());
        }
        if let Some(document) = &document {
            self.evidence.observed_application = true;
            self.evidence.observe_tier(document);
            let (items, counters) = Counters::read(document, false);
            let author = AuthorEvidence::read(
                document.get("svg_usage"),
                items,
                self.pricing.expects_svg || counters.has_svg,
            );
            self.evidence.usage = Some(counters.evidence(
                1,
                document.get("usage").and_then(JsonValue::as_object),
                &author,
                &self.pricing,
                false,
            ));
            require_completion(document)?;
        }
        if strict {
            let document = document.ok_or_else(invalid_image)?;
            if !media_type(&self.headers).eq_ignore_ascii_case("application/json") {
                return Err(invalid_image());
            }
            validate_result(&document, self.format)?;
            self.evidence.completed = true;
            if self.user_streaming {
                self.state = State::Converted(Box::new(Converted::new(document)));
                return Ok(Some("text/event-stream"));
            }
        } else {
            self.evidence.invalid_legacy_result = self
                .evidence
                .usage
                .as_ref()
                .is_none_or(|usage| usage.images == 0);
            self.evidence.completed = !self.evidence.invalid_legacy_result;
        }
        self.state = State::Buffered(body);
        Ok(None)
    }
}

impl Converted {
    fn new(document: JsonValue) -> Self {
        let JsonValue::Object(mut fields) = document else {
            unreachable!()
        };
        let Some(JsonValue::Array(items)) = fields.remove("data") else {
            unreachable!()
        };
        let created = fields
            .remove("created")
            .expect("validated result has a timestamp");
        Self {
            fields,
            items: items.into_iter().peekable(),
            created,
        }
    }

    fn event(&self, item: JsonValue, last: bool, endpoint: ImageEndpoint) -> Bytes {
        let JsonValue::Object(item) = item else {
            unreachable!()
        };
        let mut result = self.fields.clone();
        if !last {
            result.remove("usage");
        }
        for (key, value) in item.iter() {
            result.insert(key, value.clone());
        }
        result.insert("created_at", self.created.clone());
        result.insert("type", JsonValue::String(endpoint.completed().to_owned()));
        let encoded = JsonValue::Object(result).encode(true);
        let mut output = Vec::with_capacity(16 + endpoint.completed().len() + encoded.len());
        output.extend_from_slice(b"event: ");
        output.extend_from_slice(endpoint.completed().as_bytes());
        output.extend_from_slice(b"\ndata: ");
        output.extend_from_slice(&encoded);
        output.extend_from_slice(b"\n\n");
        output.into()
    }
}

struct StreamConfig<'a> {
    streaming: bool,
    endpoint: ImageEndpoint,
    pricing: &'a Pricing<'a>,
}

impl SseExchange {
    async fn next(
        &mut self,
        upstream: &mut Response,
        config: StreamConfig<'_>,
        evidence: &mut ImageEvidence,
    ) -> Result<Option<Bytes>, ImageError> {
        loop {
            if self.pending.is_empty() {
                let Some(chunk) = upstream
                    .next_chunk()
                    .await
                    .map_err(|error| ImageError::transport(error, false))?
                else {
                    self.decoder
                        .finish()
                        .map_err(|error| ImageError::indeterminate(error.code()))?;
                    if self.seen.is_empty() {
                        return Err(ImageError::indeterminate("execution_indeterminate"));
                    }
                    return Ok(None);
                };
                self.pending = chunk;
            }
            let mut remaining = self.pending.as_ref();
            let frame = self
                .decoder
                .next_frame(&mut remaining)
                .map_err(|error| ImageError::indeterminate(error.code()))?;
            let consumed = self.pending.len() - remaining.len();
            self.pending = self.pending.slice(consumed..);
            let Some(frame) = frame else {
                continue;
            };
            if let SsePayload::Json(event) = frame.payload {
                let first = !evidence.observed_application;
                evidence.observed_application = true;
                evidence.first_event_at.get_or_insert_with(Instant::now);
                let kind = event.get("type").and_then(JsonValue::as_str).unwrap_or("");
                if kind == "error" {
                    let failure = ImageError::event(&event, first);
                    if failure.outcome == ExecutionOutcome::RejectedBeforeOutput {
                        evidence.record_rejection();
                    }
                    return Err(failure);
                }
                if kind == config.endpoint.completed() {
                    let id = event.get("image_index").map_or_else(
                        || CompletionId::Content(fingerprint(&event)),
                        |index| CompletionId::Index(fingerprint(index)),
                    );
                    let duplicate = !self.seen.insert(id);
                    evidence.observe_tier(&event);
                    evidence.usage = Some(self.usage.observe(&event, duplicate, config.pricing));
                    upstream
                        .mark_response_progress()
                        .map_err(|error| ImageError::transport(error, false))?;
                    if duplicate {
                        return Err(invalid_image());
                    }
                    let result = assemble(event)?;
                    if !config.streaming {
                        append_completion(&mut self.aggregated, result);
                    }
                } else if effective_progress(&event, kind) {
                    upstream
                        .mark_response_progress()
                        .map_err(|error| ImageError::transport(error, false))?;
                }
            }
            if config.streaming {
                return Ok(Some(Bytes::copy_from_slice(frame.raw)));
            }
        }
    }
}

fn effective_progress(event: &JsonValue, kind: &str) -> bool {
    matches!(kind, "image_generation.completed" | "image_edit.completed")
        || (matches!(
            kind,
            "image_generation.partial_image" | "image_edit.partial_image"
        ) && event
            .get("b64_json")
            .and_then(JsonValue::as_str)
            .is_some_and(|image| !image.is_empty()))
}

async fn collect(
    upstream: &mut Response,
    limit: usize,
    progress: bool,
) -> Result<Bytes, ImageError> {
    let mut body = Vec::new();
    while let Some(chunk) = upstream
        .next_chunk()
        .await
        .map_err(|error| ImageError::transport(error, false))?
    {
        if chunk.len() > limit - body.len() {
            return Err(ImageError::indeterminate("upstream_response_too_large"));
        }
        if progress {
            upstream
                .mark_response_progress()
                .map_err(|error| ImageError::transport(error, false))?;
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body.into())
}

fn append_completion(aggregate: &mut Option<JsonObject>, mut result: JsonObject) {
    if let Some(aggregate) = aggregate {
        let Some(JsonValue::Array(items)) = result.remove("data") else {
            unreachable!()
        };
        let Some(JsonValue::Array(data)) = aggregate.get_mut("data") else {
            unreachable!()
        };
        data.extend(items);
    } else {
        *aggregate = Some(result);
    }
}

fn require_completion(document: &JsonValue) -> Result<(), ImageError> {
    if let Some(status) = document.get("status") {
        match status.as_str() {
            Some("completed") => {}
            Some("failed" | "cancelled") => {
                return Err(ImageError::new(
                    502,
                    "upstream_execution_failed",
                    ExecutionOutcome::ProviderFailed,
                ));
            }
            _ => return Err(ImageError::indeterminate("execution_indeterminate")),
        }
    }
    Ok(())
}

fn invalid_image() -> ImageError {
    ImageError::indeterminate("invalid_upstream_image")
}

fn validate_result(
    document: &JsonValue,
    required: Option<RequiredFormat>,
) -> Result<(), ImageError> {
    require_completion(document)?;
    if document.get("error").is_some()
        || document.get("type").is_some()
        || document
            .get("created")
            .and_then(JsonValue::as_i64)
            .is_none_or(|time| time < 0)
    {
        return Err(invalid_image());
    }
    let items = document
        .get("data")
        .and_then(JsonValue::as_array)
        .filter(|items| !items.is_empty())
        .ok_or_else(invalid_image)?;
    for item in items {
        let encoded = item
            .get("b64_json")
            .and_then(JsonValue::as_str)
            .filter(|image| item.get("error").is_none() && canonical_base64(image))
            .ok_or_else(invalid_image)?;
        if let Some(format) = required {
            let bytes = STANDARD
                .decode(&encoded[..encoded.len().min(5464)])
                .expect("a canonical base64 prefix of complete quartets");
            if !format_matches(format, &bytes) {
                return Err(ImageError::indeterminate("invalid_upstream_image_format"));
            }
        }
    }
    Ok(())
}

fn format_matches(format: RequiredFormat, bytes: &[u8]) -> bool {
    match format {
        RequiredFormat::Gif => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        RequiredFormat::Svg => {
            let text = String::from_utf8_lossy(&bytes[..bytes.len().min(4096)]);
            let mut header = text.trim_start_matches('\u{feff}');
            loop {
                header = header.trim_start();
                if let Some(comment) = header
                    .strip_prefix("<!--")
                    .and_then(|text| text.split_once("-->"))
                {
                    header = comment.1;
                } else if let Some(instruction) = header
                    .strip_prefix("<?")
                    .and_then(|text| text.split_once("?>"))
                {
                    header = instruction.1;
                } else {
                    break;
                }
            }
            header
                .strip_prefix("<svg")
                .and_then(|tail| tail.chars().next())
                .is_some_and(|delimiter| {
                    delimiter.is_whitespace() || matches!(delimiter, '>' | '/')
                })
        }
    }
}

fn assemble(event: JsonValue) -> Result<JsonObject, ImageError> {
    let JsonValue::Object(mut fields) = event else {
        return Err(invalid_image());
    };
    fields.remove("type");
    if fields.get("data").is_none() {
        let image = fields.remove("b64_json").ok_or_else(invalid_image)?;
        let created = fields.remove("created_at").ok_or_else(invalid_image)?;
        let mut item = JsonObject::new();
        item.insert("b64_json", image);
        if let Some(revised) = fields.remove("revised_prompt") {
            item.insert("revised_prompt", revised);
        }
        let mut result = JsonObject::new();
        result.insert("created", created);
        result.insert("data", JsonValue::Array(vec![JsonValue::Object(item)]));
        for (key, value) in fields.iter() {
            result.insert(key, value.clone());
        }
        fields = result;
    }
    let result = JsonValue::Object(fields);
    validate_result(&result, None)?;
    let JsonValue::Object(fields) = result else {
        unreachable!()
    };
    Ok(fields)
}

fn safe_headers(source: &HeaderMap) -> HeaderMap {
    let mut headers = HeaderMap::new();
    let nominated: Vec<_> = connection_names(source).collect();
    for name in [
        "content-type",
        "x-codex-imagegen-request-id",
        "x-codex-turn-state",
    ] {
        if nominated.iter().any(|hop| hop.eq_ignore_ascii_case(name)) {
            continue;
        }
        if let Some(value) = source.get(name).filter(|value| {
            value.len() <= 8192
                && (name != "x-codex-turn-state" || valid_turn_state(value.as_bytes()))
        }) {
            headers.insert(name, value.clone());
        }
    }
    headers
}

fn media_type(headers: &HeaderMap) -> &str {
    headers
        .get(header::CONTENT_TYPE)
        .filter(|value| value.len() <= 256)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map_or("", str::trim)
}

/// Match wire JSON equality for duplicate completion detection without retaining image bodies.
fn fingerprint(value: &JsonValue) -> [u8; 32] {
    fn normalized(value: &str) -> Cow<'_, str> {
        if value.is_ascii() || is_nfc(value) {
            Cow::Borrowed(value)
        } else {
            Cow::Owned(value.nfc().collect())
        }
    }
    fn text(value: &str, out: &mut Sha256) {
        out.update(value.len().to_le_bytes());
        out.update(value);
    }
    fn walk(value: &JsonValue, out: &mut Sha256) {
        match value {
            JsonValue::Null => out.update(b"n"),
            JsonValue::Bool(value) => out.update(if *value { b"t" } else { b"f" }),
            JsonValue::Number(value) => {
                out.update(b"d");
                text(&value.to_string(), out);
            }
            JsonValue::String(value) => {
                out.update(b"s");
                text(&normalized(value), out);
            }
            JsonValue::Array(items) => {
                out.update(b"a");
                out.update(items.len().to_le_bytes());
                for item in items {
                    walk(item, out);
                }
            }
            JsonValue::Object(fields) => {
                out.update(b"o");
                out.update(fields.len().to_le_bytes());
                let mut members: Vec<_> = fields
                    .iter()
                    .map(|(key, value)| (normalized(key), value))
                    .collect();
                members.sort_unstable_by(|a, b| a.0.cmp(&b.0));
                for (key, value) in members {
                    text(&key, out);
                    walk(value, out);
                }
            }
        }
    }
    let mut digest = Sha256::new();
    walk(value, &mut digest);
    digest.finalize().into()
}
