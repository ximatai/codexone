use std::{fmt, sync::LazyLock};

use codexone_http_upstream::Error as TransportError;
use codexone_wire::{JsonObject, JsonValue};
use http::HeaderMap;
use regex::Regex;

use crate::connection_names;

/// Execution certainty, independent of the public HTTP status and of available usage.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionOutcome {
    NotDispatched,
    RejectedBeforeOutput,
    ProviderFailed,
    Indeterminate,
}

pub struct ImageError {
    pub status: u16,
    pub code: &'static str,
    pub outcome: ExecutionOutcome,
    pub upstream_status: Option<u16>,
    pub retry_after: Option<String>,
    pub cooldown_seconds: Option<u64>,
    pub cancelled: bool,
    provider_error: Option<Box<JsonObject>>,
}

impl ImageError {
    pub(crate) fn new(status: u16, code: &'static str, outcome: ExecutionOutcome) -> Self {
        Self {
            status,
            code,
            outcome,
            upstream_status: None,
            retry_after: None,
            cooldown_seconds: None,
            cancelled: false,
            provider_error: None,
        }
    }

    pub(crate) fn input(status: u16, code: &'static str) -> Self {
        Self::new(status, code, ExecutionOutcome::NotDispatched)
    }

    pub(crate) fn indeterminate(code: &'static str) -> Self {
        Self::new(502, code, ExecutionOutcome::Indeterminate)
    }

    pub fn cancelled(outcome: ExecutionOutcome) -> Self {
        let mut failure = Self::new(502, "execution_indeterminate", outcome);
        failure.cancelled = true;
        failure
    }

    pub fn force_stopped() -> Self {
        Self::new(
            503,
            "account_force_stopped",
            ExecutionOutcome::Indeterminate,
        )
    }

    pub(crate) fn transport(error: TransportError, before_headers: bool) -> Self {
        use TransportError::*;
        let not_dispatched = before_headers
            && matches!(
                error,
                InvalidRequest
                    | InvalidProxy
                    | Connect
                    | ConnectTimeout
                    | ProxyConnect
                    | ProxyAuthenticationRequired
                    | Tls
            );
        let outcome = if not_dispatched {
            ExecutionOutcome::NotDispatched
        } else {
            ExecutionOutcome::Indeterminate
        };
        match error {
            Cancelled => Self::cancelled(outcome),
            FirstResponseTimeout => Self::new(504, "execution_first_response_timeout", outcome),
            ProgressTimeout => Self::new(504, "execution_progress_timeout", outcome),
            DeadlineExceeded => Self::new(504, "execution_deadline_exceeded", outcome),
            ResponseTooLarge => Self::indeterminate("upstream_response_too_large"),
            ProxyAuthenticationRequired => {
                let mut failure = Self::new(502, "upstream_proxy_authentication_required", outcome);
                failure.upstream_status = Some(407);
                failure
            }
            InvalidProxy | ProxyConnect => Self::new(502, "upstream_proxy_failed", outcome),
            _ => Self::new(502, "execution_indeterminate", outcome),
        }
    }

    pub(crate) fn http(status: u16, headers: &HeaderMap, document: Option<&JsonValue>) -> Self {
        let error = document.and_then(|doc| {
            doc.get("error")
                .filter(|error| **error != JsonValue::Null)
                .or_else(|| doc.get("detail"))
        });
        let mut retry = headers.get_all("retry-after").iter();
        let first = retry.next().and_then(|value| value.to_str().ok());
        let retry = first.filter(|_| retry.next().is_none());
        let internal = retry.and_then(delay);
        let public = retry
            .filter(|_| {
                !connection_names(headers).any(|name| name.eq_ignore_ascii_case("retry-after"))
            })
            .and_then(valid_retry);
        Self::provider(Some(i64::from(status)), error, internal, public, true)
    }

    pub(crate) fn event(event: &JsonValue, first: bool) -> Self {
        let status = event
            .get("status")
            .and_then(JsonValue::as_i64)
            .or_else(|| event.get("status_code").and_then(JsonValue::as_i64));
        let can_certify = first
            && !carries_output(event)
            && event
                .get("response")
                .is_none_or(|response| !carries_output(response));
        Self::provider(
            status,
            event.get("error").or(Some(event)),
            None,
            nested_retry(event.get("headers")),
            can_certify,
        )
    }

    fn provider(
        status: Option<i64>,
        value: Option<&JsonValue>,
        retry: Option<u64>,
        advice: Option<String>,
        can_certify: bool,
    ) -> Self {
        let kind = value
            .and_then(|v| v.get("type"))
            .and_then(JsonValue::as_str);
        let explicit_code = value
            .and_then(|v| v.get("code"))
            .and_then(JsonValue::as_str);
        let code = explicit_code.or(kind).unwrap_or("");
        let rejected = status.map_or_else(
            || {
                [explicit_code, kind]
                    .into_iter()
                    .flatten()
                    .any(permanent_rejection)
            },
            |s| (400..=499).contains(&s),
        );
        let outcome = if rejected && can_certify {
            ExecutionOutcome::RejectedBeforeOutput
        } else {
            ExecutionOutcome::Indeterminate
        };
        let (downstream, mapped) = match status {
            Some(503) => (503, "upstream_unavailable"),
            Some(500..=599) => (502, "upstream_unavailable"),
            Some(401) => (502, "upstream_authentication_rejected"),
            _ if authentication(code) => (502, "upstream_authentication_rejected"),
            Some(429) => (429, "upstream_rate_limited"),
            _ if rate_limit(code) => (429, "upstream_rate_limited"),
            _ if code == "server_is_overloaded" => (502, "upstream_unavailable"),
            Some(s @ 400..=499) => (s as u16, "upstream_rejected"),
            None if rejected => (400, "upstream_rejected"),
            _ => (502, "upstream_rejected"),
        };
        let mut failure = Self::new(downstream, mapped, outcome);
        failure.upstream_status = status.and_then(|s| u16::try_from(s).ok());
        if mapped != "upstream_authentication_rejected" {
            failure.provider_error = sanitize(value).map(Box::new);
            failure.retry_after =
                nested_retry(value.and_then(|error| error.get("headers"))).or(advice);
        }
        if matches!(mapped, "upstream_rate_limited" | "upstream_unavailable") {
            failure.cooldown_seconds = retry.or_else(|| {
                value
                    .and_then(|error| error.get("resets_in_seconds"))
                    .and_then(JsonValue::as_i64)
                    .map(|seconds| seconds.clamp(1, 3600) as u64)
            });
        }
        failure
    }

    pub fn account_cooldown(&self, observed_at: i64) -> Option<u64> {
        self.cooldown_seconds.or_else(|| {
            let reset = self.provider_error.as_ref()?.get("resets_at")?.as_i64()?;
            (self.code == "upstream_rate_limited" && reset > observed_at)
                .then(|| reset.saturating_sub(observed_at).min(3600) as u64)
        })
    }

    /// Retry advice for the HTTP error envelope, with the bounded internal fallback.
    pub fn retry_header(&self) -> Option<String> {
        self.retry_after
            .clone()
            .or_else(|| self.cooldown_seconds.map(|seconds| seconds.to_string()))
    }

    pub fn json(&self, request_id: &str) -> JsonValue {
        let mut wrapper = JsonObject::new();
        wrapper.insert("error", JsonValue::Object(self.error_fields(request_id)));
        JsonValue::Object(wrapper)
    }

    /// A replacement error event for an already committed stream. Call only while the downstream
    /// writer is available. Never forward the provider's raw error frame.
    pub fn sse(&self, request_id: &str) -> Vec<u8> {
        let mut fields = self.error_fields(request_id);
        if let Some(retry) = self
            .retry_after
            .as_ref()
            .filter(|_| fields.get("headers").is_none())
        {
            let mut headers = JsonObject::new();
            headers.insert("retry-after", JsonValue::String(retry.clone()));
            fields.insert("headers", JsonValue::Object(headers));
        }
        let mut event = JsonObject::new();
        event.insert("type", JsonValue::String("error".to_owned()));
        event.insert("error", JsonValue::Object(fields));
        let mut frame = b"event: error\ndata: ".to_vec();
        frame.extend(JsonValue::Object(event).encode(true));
        frame.extend_from_slice(b"\n\n");
        frame
    }

    fn error_fields(&self, request_id: &str) -> JsonObject {
        let mut fields = self.provider_error.as_deref().cloned().unwrap_or_default();
        let kind = if self.status < 500 {
            "invalid_request_error"
        } else {
            "server_error"
        };
        let message = match self.code {
            "request_too_large" => {
                "Request body is too large. Reduce conversation context or attached images before trying again."
            }
            "model_not_allowed" => {
                "The selected model is not available for this request. Choose a model enabled for this operation and allowed by your API key."
            }
            "unsupported_svg_model_selection" => {
                "Choosing an SVG author model is not supported. Omit the svg object to use the image endpoint default. The request was not dispatched."
            }
            "unsupported_image_format_combination" => {
                "This image format cannot use streaming, partial images, masks or output compression. SVG also requires generation with one image and no prompt rewriter. The request was not dispatched."
            }
            "invalid_upstream_image_format" => {
                "The provider returned a different or unrecognized image format."
            }
            _ => "Gateway request failed.",
        };
        let reference = request_id.len() == 36
            && request_id.bytes().enumerate().all(|(index, byte)| {
                if matches!(index, 8 | 13 | 18 | 23) {
                    byte == b'-'
                } else {
                    byte.is_ascii_hexdigit()
                }
            });
        let message = if reference {
            format!("{message} Reference: {request_id}.")
        } else {
            message.to_owned()
        };
        for (key, default) in [
            ("type", kind.to_owned()),
            ("code", self.code.to_owned()),
            ("message", message),
        ] {
            if fields.get(key).is_none() {
                fields.insert(key, JsonValue::String(default));
            }
        }
        fields.insert("request_id", JsonValue::String(request_id.to_owned()));
        fields
    }
}

impl fmt::Debug for ImageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ImageError")
            .field("status", &self.status)
            .field("code", &self.code)
            .field("outcome", &self.outcome)
            .finish_non_exhaustive()
    }
}

impl fmt::Display for ImageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code)
    }
}

impl std::error::Error for ImageError {}

fn authentication(code: &str) -> bool {
    matches!(
        code,
        "invalid_api_key"
            | "invalid_token"
            | "authentication_error"
            | "unauthorized"
            | "token_expired"
    )
}

fn rate_limit(code: &str) -> bool {
    matches!(
        code,
        "rate_limit_exceeded"
            | "rate_limit_error"
            | "usage_limit_reached"
            | "insufficient_quota"
            | "usage_not_included"
    )
}

fn permanent_rejection(code: &str) -> bool {
    rate_limit(code)
        || authentication(code)
        || matches!(
            code,
            "invalid_request_error"
                | "invalid_request"
                | "permission_denied"
                | "access_denied"
                | "model_not_found"
                | "content_policy_violation"
                | "unsupported_parameter"
                | "budget_reached"
        )
}

fn carries_output(document: &JsonValue) -> bool {
    ["output", "data"].iter().any(|key| {
        document
            .get(key)
            .is_some_and(|value| value.as_array() != Some(&[]))
    }) || ["item", "delta", "b64_json"]
        .iter()
        .any(|key| document.get(key).is_some())
        || ["usage", "svg_usage"].iter().any(|key| {
            document
                .get(key)
                .is_some_and(|value| *value != JsonValue::Null)
        })
}

fn delay(raw: &str) -> Option<u64> {
    ((1..=10).contains(&raw.len()) && raw.bytes().all(|byte| byte.is_ascii_digit())).then(|| {
        raw.parse::<u64>()
            .expect("at most ten digits")
            .clamp(1, 3600)
    })
}

fn valid_retry(raw: &str) -> Option<String> {
    if raw.len() > 64
        || !raw
            .bytes()
            .all(|byte| byte == 9 || (32..=126).contains(&byte))
    {
        return None;
    }
    let value = raw.trim();
    if delay(value).is_some()
        || (value.len() == 29
            && httpdate::parse_http_date(value)
                .is_ok_and(|date| httpdate::fmt_http_date(date) == value))
    {
        Some(value.to_owned())
    } else {
        None
    }
}

fn nested_retry(value: Option<&JsonValue>) -> Option<String> {
    let mut matches = value?
        .as_object()?
        .iter()
        .filter(|(key, _)| key.eq_ignore_ascii_case("retry-after"));
    let (_, value) = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    valid_retry(value.as_str()?)
}

fn redact(value: &str) -> String {
    static IDS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\b(org|user|proj|acct|account)[-_][A-Za-z0-9_-]{4,}").unwrap()
    });
    static EMAILS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}").unwrap());
    let clipped = value
        .char_indices()
        .nth(4096)
        .map_or(value, |(end, _)| &value[..end]);
    IDS.replace_all(&EMAILS.replace_all(clipped, "[redacted]"), "[redacted]")
        .into_owned()
}

fn sanitize(value: Option<&JsonValue>) -> Option<JsonObject> {
    let mut result = JsonObject::new();
    if let Some(text) = value?.as_str() {
        result.insert("message", JsonValue::String(redact(text)));
    } else {
        let object = value?.as_object()?;
        for (key, value) in object.iter() {
            match (key, value) {
                ("type" | "code" | "param" | "message" | "plan_type", JsonValue::String(text)) => {
                    result.insert(key, JsonValue::String(redact(text)));
                }
                ("resets_at" | "resets_in_seconds", JsonValue::Number(_)) => {
                    result.insert(key, value.clone());
                }
                _ => {}
            }
        }
        if let Some(retry) = nested_retry(object.get("headers")) {
            let mut headers = JsonObject::new();
            headers.insert("retry-after", JsonValue::String(retry));
            result.insert("headers", JsonValue::Object(headers));
        }
    }
    (!result.is_empty()).then_some(result)
}
