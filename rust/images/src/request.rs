use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_http_upstream::{Bytes, CancellationToken, RequestBody};
use codexone_wire::{JsonObject, JsonValue};
use http::{HeaderMap, HeaderValue, Method, Request, Uri, header};
use memchr::memmem;

use crate::{
    ExecutionOutcome, ImageError, connection_names, metadata,
    payload::{MAX_IMAGES, MAX_TOTAL_IMAGES, inline_size, raster_type},
    valid_turn_state,
};

pub const MAX_REQUEST_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ImageEndpoint {
    Generation,
    Edit,
}

impl ImageEndpoint {
    pub(crate) fn completed(self) -> &'static str {
        match self {
            Self::Generation => "image_generation.completed",
            Self::Edit => "image_edit.completed",
        }
    }

    fn upstream_path(self) -> &'static str {
        match self {
            Self::Generation => "/backend-api/codex/images/generations",
            Self::Edit => "/backend-api/codex/images/edits",
        }
    }
}

#[derive(Clone, Copy)]
pub struct ImageRoute {
    pub endpoint: ImageEndpoint,
    multipart: bool,
}

impl ImageRoute {
    /// Match the request path (without query) before method and media type validation.
    pub fn from_path(path: &str) -> Option<Self> {
        let (suffix, public) = if let Some(path) = path.strip_prefix("/v1/") {
            (path, true)
        } else {
            (path.strip_prefix("/backend-api/codex/")?, false)
        };
        match suffix {
            "images/generations" => Some(Self {
                endpoint: ImageEndpoint::Generation,
                multipart: false,
            }),
            "images/edits" => Some(Self {
                endpoint: ImageEndpoint::Edit,
                multipart: public,
            }),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum RequiredFormat {
    Gif,
    Svg,
}

pub struct ImageRequest {
    pub(crate) endpoint: ImageEndpoint,
    pub(crate) streaming: bool,
    pub(crate) aggregate_sse: bool,
    pub(crate) format: Option<RequiredFormat>,
    pub(crate) upstream_streaming: bool,
    body: Bytes,
    model: String,
    service_tier: Option<String>,
    turn_state: Option<HeaderValue>,
}

impl ImageRequest {
    /// Validate a bounded ingress body against deployed models. Apply the caller's per-Key image
    /// capability to the selected model before capacity acquisition and persisted admission.
    pub fn parse(
        route: ImageRoute,
        method: &Method,
        headers: &HeaderMap,
        body: Bytes,
        default_model: Option<&str>,
        configured_models: &[&str],
        cancel: &CancellationToken,
    ) -> Result<Self, ImageError> {
        if *method != Method::POST {
            return Err(ImageError::input(405, "method_not_allowed"));
        }
        if cancel.is_cancelled() {
            return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
        }
        if body.len() > MAX_REQUEST_BYTES {
            return Err(ImageError::input(413, "request_too_large"));
        }
        let content_types = headers.get_all(header::CONTENT_TYPE);
        let mut types = content_types.iter();
        let media = types
            .next()
            .and_then(|value| value.to_str().ok())
            .unwrap_or("");
        if types.next().is_some() || headers.contains_key(header::CONTENT_ENCODING) {
            return Err(unsupported_media());
        }
        let lower = media.to_ascii_lowercase();
        let is_multipart = lower.starts_with("multipart/form-data");
        let (mut fields, image_bytes) = if is_multipart && route.multipart {
            multipart(&body, media, cancel)?
        } else if lower.starts_with("application/json") {
            let root = JsonValue::decode_rejecting_duplicates(
                &body,
                &[
                    "model",
                    "stream",
                    "output_format",
                    "images",
                    "mask",
                    "n",
                    "partial_images",
                    "output_compression",
                    "prompt_rewriter",
                    "svg",
                ],
            )
            .map_err(|_| ImageError::input(400, "invalid_json"))?;
            let JsonValue::Object(fields) = root else {
                return Err(ImageError::input(400, "invalid_json"));
            };
            (fields, 0)
        } else {
            return Err(unsupported_media());
        };

        let selected = fields.get("model");
        let stream = fields.get("stream");
        if selected.is_some_and(|value| value.as_str().is_none())
            || stream.is_some_and(|value| value.as_bool().is_none())
        {
            return Err(ImageError::input(400, "invalid_request"));
        }
        let model = selected
            .and_then(JsonValue::as_str)
            .or(default_model)
            .filter(|model| configured_models.contains(model))
            .ok_or_else(|| ImageError::input(403, "model_not_allowed"))?
            .to_owned();
        let image_bytes = if is_multipart {
            image_bytes
        } else {
            reference_bytes(&fields, cancel)?
        };
        if image_bytes > MAX_TOTAL_IMAGES {
            return Err(ImageError::input(413, "image_too_large"));
        }
        let streaming = stream.and_then(JsonValue::as_bool) == Some(true);
        let service_tier = metadata(fields.get("service_tier"));
        if fields
            .get("svg")
            .is_some_and(|value| *value != JsonValue::Null)
        {
            return Err(ImageError::input(400, "unsupported_svg_model_selection"));
        }
        let format = fields.get("output_format").and_then(JsonValue::as_str);
        let required = match format {
            Some("gif") => Some(RequiredFormat::Gif),
            Some("svg") => Some(RequiredFormat::Svg),
            _ => None,
        };
        let generation = route.endpoint == ImageEndpoint::Generation;
        let legacy = matches!(format, None | Some("png" | "jpeg" | "webp"));
        if required.is_some()
            && (streaming
                || ["partial_images", "output_compression", "mask"]
                    .iter()
                    .any(|key| fields.get(key).is_some())
                || (required == Some(RequiredFormat::Svg)
                    && (!generation
                        || fields
                            .get("n")
                            .is_some_and(|value| value.as_i64() != Some(1))
                        || fields.get("prompt_rewriter").is_some())))
        {
            return Err(ImageError::input(
                400,
                "unsupported_image_format_combination",
            ));
        }
        let turn_state = inbound_turn_state(headers)?;
        if cancel.is_cancelled() {
            return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
        }
        let upstream_streaming = streaming && (generation || !legacy);
        let missing_model = selected.is_none();
        if missing_model {
            fields.insert("model", JsonValue::String(model.clone()));
        }
        if streaming != upstream_streaming {
            fields.insert("stream", JsonValue::Bool(upstream_streaming));
        }
        let body = if is_multipart || missing_model || streaming != upstream_streaming {
            JsonValue::Object(fields).encode(false).into()
        } else {
            body
        };
        Ok(Self {
            endpoint: route.endpoint,
            streaming,
            aggregate_sse: generation && legacy,
            format: required,
            upstream_streaming,
            body,
            model,
            service_tier,
            turn_state,
        })
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    pub fn streaming(&self) -> bool {
        self.streaming
    }

    pub fn service_tier(&self) -> Option<&str> {
        self.service_tier.as_deref()
    }

    pub fn turn_state(&self) -> Option<&HeaderValue> {
        self.turn_state.as_ref()
    }

    /// The caller supplies the shared Codex client fingerprint/metadata policy's output and a
    /// separately sourced account credential map. Raw downstream credentials are never forwarded.
    pub fn upstream_request(
        &self,
        upstream_base: &Uri,
        client_metadata: &HeaderMap,
        account_headers: &HeaderMap,
    ) -> Result<Request<RequestBody>, ImageError> {
        let mut uri = upstream_base.clone().into_parts();
        let mut path = self.endpoint.upstream_path().to_owned();
        if let Some(query) = upstream_base.query() {
            path.push('?');
            path.push_str(query);
        }
        let invalid = || {
            ImageError::new(
                502,
                "invalid_upstream_request",
                ExecutionOutcome::NotDispatched,
            )
        };
        uri.path_and_query = Some(path.parse().map_err(|_| invalid())?);
        let uri = Uri::from_parts(uri).map_err(|_| invalid())?;
        if !matches!(uri.scheme_str(), Some("http" | "https")) || uri.authority().is_none() {
            return Err(invalid());
        }
        let mut request = Request::post(uri)
            .header(header::CONTENT_TYPE, "application/json")
            .header(
                header::ACCEPT,
                if self.upstream_streaming {
                    "text/event-stream"
                } else {
                    "application/json"
                },
            )
            .body(RequestBody::bytes(self.body.clone()))
            .map_err(|_| invalid())?;
        let headers = request.headers_mut();
        let mut extension_count = usize::from(self.turn_state.is_some());
        if let Some(state) = &self.turn_state {
            headers.insert("x-codex-turn-state", state.clone());
        }
        let hop_by_hop: Vec<_> = connection_names(client_metadata).collect();
        for (name, value) in client_metadata {
            let key = name.as_str();
            if key == "x-codex-turn-state"
                || value.len() > 8192
                || hop_by_hop.iter().any(|hop| hop.eq_ignore_ascii_case(key))
            {
                continue;
            }
            if key.starts_with("x-codex-") {
                if extension_count == 32 {
                    continue;
                }
                extension_count += 1;
            } else if !matches!(
                key,
                "user-agent"
                    | "originator"
                    | "version"
                    | "session_id"
                    | "x-session-id"
                    | "conversation_id"
                    | "x-conversation-id"
                    | "session-id"
                    | "thread-id"
                    | "openai-beta"
                    | "x-openai-subagent"
                    | "x-openai-memgen-request"
            ) {
                continue;
            }
            headers.append(name.clone(), value.clone());
        }
        for name in ["authorization", "chatgpt-account-id"] {
            if let Some(value) = account_headers.get(name) {
                headers.insert(name, value.clone());
            }
        }
        Ok(request)
    }
}

fn inbound_turn_state(headers: &HeaderMap) -> Result<Option<HeaderValue>, ImageError> {
    let values = headers.get_all("x-codex-turn-state");
    let mut values = values.iter();
    let Some(state) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(ImageError::input(400, "conflicting_turn_state"));
    }
    if !valid_turn_state(state.as_bytes())
        || connection_names(headers).any(|name| name.eq_ignore_ascii_case("x-codex-turn-state"))
    {
        return Err(ImageError::input(400, "invalid_turn_state"));
    }
    Ok(Some(state.clone()))
}

fn unsupported_media() -> ImageError {
    ImageError::input(415, "unsupported_content_type")
}

fn reference_bytes(fields: &JsonObject, cancel: &CancellationToken) -> Result<usize, ImageError> {
    let mut total = 0;
    if let Some(value) = fields.get("images") {
        let invalid = || ImageError::input(400, "invalid_image");
        let items = value
            .as_array()
            .filter(|items| items.len() <= MAX_IMAGES)
            .ok_or_else(invalid)?;
        for item in items {
            let url = item
                .get("image_url")
                .and_then(JsonValue::as_str)
                .ok_or_else(invalid)?;
            total += inline_size(url, cancel)?;
        }
    }
    if let Some(mask) = fields.get("mask") {
        let url = mask
            .get("image_url")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| ImageError::input(400, "invalid_mask"))?;
        total += inline_size(url, cancel)?;
    }
    Ok(total)
}

fn multipart(
    mut body: &[u8],
    media: &str,
    cancel: &CancellationToken,
) -> Result<(JsonObject, usize), ImageError> {
    let mut parameters = media.split(';').map(str::trim);
    let boundary = parameters
        .next()
        .filter(|media| media.eq_ignore_ascii_case("multipart/form-data"))
        .and_then(|_| parameters.next())
        .and_then(|param| param.strip_prefix("boundary="))
        .filter(|_| parameters.next().is_none())
        .ok_or_else(invalid_multipart)?;
    let boundary = unquote(boundary).unwrap_or(boundary);
    if !(1..=70).contains(&boundary.len())
        || !boundary
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"'()+_,-./:=?".contains(&byte))
    {
        return Err(invalid_multipart());
    }
    body = body
        .strip_prefix(format!("--{boundary}\r\n").as_bytes())
        .ok_or_else(invalid_multipart)?;
    let boundary = format!("\r\n--{boundary}");
    let delimiter = memmem::Finder::new(boundary.as_bytes());
    let mut fields = JsonObject::new();
    let mut images = Vec::new();
    let mut total = 0;
    for _ in 0..40 {
        let end = memmem::find(&body[..body.len().min(4100)], b"\r\n\r\n")
            .ok_or_else(invalid_multipart)?;
        let headers = std::str::from_utf8(&body[..end]).map_err(|_| invalid_multipart())?;
        let (name, media_type) = part_headers(headers)?;
        let contents = &body[end + 4..];
        let end = delimiter.find(contents).ok_or_else(invalid_multipart)?;
        let data = &contents[..end];
        body = &contents[end + boundary.len()..];
        match name {
            "image" | "image[]" | "mask" => {
                if name == "mask" && fields.get("mask").is_some() {
                    return Err(ImageError::input(400, "invalid_mask"));
                }
                if name != "mask" && images.len() == MAX_IMAGES {
                    return Err(ImageError::input(400, "invalid_image"));
                }
                let media = raster_type(data, media_type, cancel)?;
                total += data.len();
                if total > MAX_TOTAL_IMAGES {
                    return Err(ImageError::input(413, "image_too_large"));
                }
                let mut url = format!("data:{media};base64,");
                STANDARD.encode_string(data, &mut url);
                let mut item = JsonObject::new();
                item.insert("image_url", JsonValue::String(url));
                if name == "mask" {
                    fields.insert("mask", JsonValue::Object(item));
                } else {
                    images.push(JsonValue::Object(item));
                }
            }
            _ => {
                if name == "images" || fields.get(name).is_some() || data.len() > 32_768 {
                    return Err(invalid_multipart());
                }
                let text = std::str::from_utf8(data).map_err(|_| invalid_multipart())?;
                let value = match name {
                    "n" | "partial_images" | "output_compression" => JsonValue::Number(
                        text.parse::<i64>()
                            .map_err(|_| ImageError::input(400, "invalid_request"))?
                            .into(),
                    ),
                    "stream" => JsonValue::Bool(
                        text.parse::<bool>()
                            .map_err(|_| ImageError::input(400, "invalid_request"))?,
                    ),
                    _ => JsonValue::String(text.to_owned()),
                };
                fields.insert(name, value);
            }
        }
        match body {
            b"--" | b"--\r\n" => {
                fields.insert("images", JsonValue::Array(images));
                return Ok((fields, total));
            }
            _ => body = body.strip_prefix(b"\r\n").ok_or_else(invalid_multipart)?,
        }
    }
    Err(invalid_multipart())
}

fn part_headers(headers: &str) -> Result<(&str, Option<&str>), ImageError> {
    let mut disposition = None;
    let mut media = None;
    for line in headers.split("\r\n") {
        let (name, value) = line.split_once(':').ok_or_else(invalid_multipart)?;
        let target = match name.to_ascii_lowercase().as_str() {
            "content-disposition" => &mut disposition,
            "content-type" => &mut media,
            _ => return Err(invalid_multipart()),
        };
        if target.replace(value.trim()).is_some() {
            return Err(invalid_multipart());
        }
    }
    let mut attrs = disposition
        .ok_or_else(invalid_multipart)?
        .split(';')
        .map(str::trim);
    if attrs.next() != Some("form-data") {
        return Err(invalid_multipart());
    }
    let mut name = None;
    let mut filename = None;
    for attr in attrs {
        let (key, raw) = attr.split_once('=').ok_or_else(invalid_multipart)?;
        let value = unquote(raw)
            .filter(|v| !v.contains(['"', '\r', '\n']))
            .ok_or_else(invalid_multipart)?;
        let item = match key {
            "name" => &mut name,
            "filename" => &mut filename,
            _ => return Err(invalid_multipart()),
        };
        if item.replace(value).is_some() {
            return Err(invalid_multipart());
        }
    }
    Ok((
        name.filter(|value| !value.is_empty())
            .ok_or_else(invalid_multipart)?,
        media,
    ))
}

fn unquote(raw: &str) -> Option<&str> {
    raw.strip_prefix('"')?.strip_suffix('"')
}

fn invalid_multipart() -> ImageError {
    ImageError::input(400, "invalid_multipart")
}
