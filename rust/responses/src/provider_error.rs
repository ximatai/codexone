use crate::{JsonObject, JsonValue, ProtocolError, UsageEvidence, object, text};
use regex::Regex;
use std::sync::LazyLock;
use unicode_segmentation::UnicodeSegmentation;

const RATE_LIMIT: &[&str] = &[
    "rate_limit_exceeded",
    "rate_limit_error",
    "usage_limit_reached",
    "insufficient_quota",
    "usage_not_included",
];
const AUTHENTICATION: &[&str] = &[
    "invalid_api_key",
    "invalid_token",
    "authentication_error",
    "unauthorized",
    "token_expired",
];
const REQUEST_REJECTION: &[&str] = &[
    "invalid_request_error",
    "invalid_request",
    "permission_denied",
    "access_denied",
    "model_not_found",
    "content_policy_violation",
    "unsupported_parameter",
    "budget_reached",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderFailure {
    pub protocol: ProtocolError,
    pub upstream_status: Option<i64>,
    pub provider_error: Option<JsonObject>,
    pub client_retry_after: Option<String>,
    pub cooldown_seconds: Option<i64>,
    pub explicit_rejection: bool,
}

impl ProviderFailure {
    /// For an HTTP refusal before any provider events. SSE uses the first-event proof gate.
    pub fn http_rejection_usage(&self, images: bool) -> Option<UsageEvidence> {
        self.explicit_rejection
            .then(|| UsageEvidence::provider_rejection(images))
    }

    pub fn account_cooldown(&self, observed_at: i64) -> Option<i64> {
        self.cooldown_seconds.or_else(|| {
            if self.protocol.code != "upstream_rate_limited" {
                return None;
            }
            let resets_at = self.provider_error.as_ref()?.get("resets_at")?.as_i64()?;
            (resets_at > observed_at).then(|| resets_at.saturating_sub(observed_at).min(3600))
        })
    }
}

pub fn is_explicit_rejection(status: Option<i64>, error: Option<&JsonValue>) -> bool {
    if let Some(status) = status {
        return (400..=499).contains(&status);
    }
    let Some(error) = error else { return false };
    ["code", "type"]
        .iter()
        .filter_map(|member| text(error, member))
        .any(|code| {
            RATE_LIMIT.contains(&code)
                || AUTHENTICATION.contains(&code)
                || REQUEST_REJECTION.contains(&code)
        })
}

/// At most 64 KiB of a non-200 provider response is parsed. An oversized or missing body retains
/// status classification. Supply the raw Retry-After and Connection header values.
pub fn http_provider_failure(
    status: u16,
    body: Option<&[u8]>,
    retry_after: &[&str],
    connection: &[&str],
    compact: bool,
) -> ProviderFailure {
    let document = body
        .filter(|body| body.len() <= 65_536)
        .and_then(|body| JsonValue::decode(body).ok());
    let error = document.as_ref().and_then(|doc| {
        doc.get("error")
            .filter(|&error| error != &JsonValue::Null)
            .or_else(|| doc.get("detail"))
    });
    let raw = match retry_after {
        [value] => Some(*value),
        _ => None,
    };
    let hop_by_hop = connection
        .iter()
        .flat_map(|value| value.split(','))
        .any(|name| name.trim().eq_ignore_ascii_case("retry-after"));
    let client_retry_after = raw.filter(|_| !hop_by_hop).and_then(valid_retry_after);
    let cooldown = raw
        .filter(|raw| valid_delay(raw))
        .and_then(|raw| raw.parse::<i64>().ok())
        .map(|seconds| seconds.clamp(1, 3600));
    classify(
        Some(i64::from(status)),
        error,
        cooldown,
        client_retry_after,
        compact,
    )
}

pub(crate) fn event_provider_failure(event: &JsonValue) -> ProviderFailure {
    let status = numeric_field(event, "status").or_else(|| numeric_field(event, "status_code"));
    let error = event.get("error").unwrap_or(event);
    let mut failure = classify(
        status,
        Some(error),
        None,
        retry_after_in(event.get("headers")),
        false,
    );
    let explicit_status = status
        .or_else(|| numeric_field(error, "status"))
        .or_else(|| numeric_field(error, "status_code"))
        .or_else(|| numeric_field(event.get("response")?, "status_code"));
    // Client compatibility only. Keep the original evidence and account health classification.
    if explicit_status.is_none() {
        failure.protocol.status = match text(error, "code") {
            Some("server_is_overloaded") => 503,
            Some(
                "api_key_spend_limit_exceeded"
                | "project_spend_limit_exceeded"
                | "organization_spend_limit_exceeded",
            ) => 429,
            _ => failure.protocol.status,
        };
    }
    failure
}

pub(crate) fn numeric_field(value: &JsonValue, name: &str) -> Option<i64> {
    value.get(name)?.as_i64()
}

fn classify(
    status: Option<i64>,
    error: Option<&JsonValue>,
    cooldown: Option<i64>,
    retry_after: Option<&str>,
    compact: bool,
) -> ProviderFailure {
    let explicit_rejection = is_explicit_rejection(status, error);
    let code = error
        .and_then(|error| text(error, "code").or_else(|| text(error, "type")))
        .unwrap_or("");
    let provider_error = sanitized_error(error);
    let client_retry_after = provider_error
        .as_ref()
        .and_then(|error| error.get("headers"))
        .and_then(|headers| text(headers, "retry-after"))
        .or(retry_after)
        .map(str::to_owned);
    let cooldown_seconds = cooldown.or_else(|| {
        numeric_field(error?, "resets_in_seconds").map(|seconds| seconds.clamp(1, 3600))
    });
    let mut failure = ProviderFailure {
        protocol: ProtocolError::new(502, "upstream_rejected"),
        upstream_status: status,
        provider_error,
        client_retry_after,
        cooldown_seconds: None,
        explicit_rejection,
    };
    if status.is_some_and(|status| (500..=599).contains(&status)) {
        failure.protocol = unavailable(status);
        failure.cooldown_seconds = cooldown_seconds;
    } else if status == Some(401) || AUTHENTICATION.contains(&code) {
        failure.protocol = ProtocolError::new(502, "upstream_authentication_rejected");
        failure.provider_error = None;
        failure.client_retry_after = None;
    } else if status == Some(429) || RATE_LIMIT.contains(&code) {
        failure.protocol = ProtocolError::new(429, "upstream_rate_limited");
        failure.cooldown_seconds = cooldown_seconds;
    } else if code == "server_is_overloaded" {
        failure.protocol = unavailable(status);
        failure.cooldown_seconds = cooldown_seconds;
    } else {
        let downstream = match status {
            Some(status @ 400..=499) => status as u16,
            None if explicit_rejection => 400,
            _ => 502,
        };
        failure.protocol = ProtocolError::new(
            downstream,
            if compact {
                "upstream_compact_rejected"
            } else {
                "upstream_rejected"
            },
        );
    }
    failure
}

fn unavailable(status: Option<i64>) -> ProtocolError {
    ProtocolError::new(
        if status == Some(503) { 503 } else { 502 },
        "upstream_unavailable",
    )
}

fn valid_delay(value: &str) -> bool {
    (1..=10).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_digit())
}

fn valid_retry_after(value: &str) -> Option<&str> {
    if value.len() > 64 || !value.bytes().all(|b| b == b'\t' || (32..=126).contains(&b)) {
        return None;
    }
    let value = value.trim_matches([' ', '\t']);
    (valid_delay(value) || valid_http_date(value)).then_some(value)
}

fn valid_http_date(value: &str) -> bool {
    if value.len() != 29 {
        return false;
    }
    let parts: Vec<_> = value.split(' ').collect();
    let [day_name, day, month, year, time, "GMT"] = parts.as_slice() else {
        return false;
    };
    let clock: Vec<_> = time.split(':').collect();
    let [hours, minutes, seconds] = clock.as_slice() else {
        return false;
    };
    fn digits(value: &str, width: usize) -> Option<i32> {
        (value.len() == width && value.bytes().all(|b| b.is_ascii_digit()))
            .then(|| value.parse().expect("at most four decimal digits"))
    }
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let Some(month) = months
        .iter()
        .position(|name| name == month)
        .map(|index| index as i32 + 1)
    else {
        return false;
    };
    let (Some(year), Some(day), Some(hours), Some(minutes), Some(seconds)) = (
        digits(year, 4),
        digits(day, 2),
        digits(hours, 2),
        digits(minutes, 2),
        digits(seconds, 2),
    ) else {
        return false;
    };
    // Foundation's POSIX date formatter uses the Julian calendar before the Gregorian cutover.
    let gregorian = (year, month, day) >= (1582, 10, 15);
    let skip = year == 1582 && month == 10 && (5..=14).contains(&day);
    let leap = year % 4 == 0 && (!gregorian || year % 100 != 0 || year % 400 == 0);
    let days = match month {
        2 => 28 + i32::from(leap),
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if year == 0 || skip || !(1..=days).contains(&day) || hours > 23 || minutes > 59 || seconds > 59
    {
        return false;
    }

    // Julian day number, with Monday at remainder zero.
    let offset = (14 - month) / 12;
    let y = year + 4800 - offset;
    let m = month + 12 * offset - 3;
    let base = day + (153 * m + 2) / 5 + 365 * y + y / 4;
    let julian_day = if gregorian {
        base - y / 100 + y / 400 - 32045
    } else {
        base - 32083
    };
    let weekdays = ["Mon,", "Tue,", "Wed,", "Thu,", "Fri,", "Sat,", "Sun,"];
    weekdays[(julian_day % 7) as usize] == *day_name
}

fn retry_after_in(value: Option<&JsonValue>) -> Option<&str> {
    let mut headers = value?
        .as_object()?
        .iter()
        .filter(|(key, _)| key.eq_ignore_ascii_case("retry-after"));
    let (_, first) = headers.next()?;
    if headers.next().is_some() {
        return None;
    }
    valid_retry_after(first.as_str()?)
}

fn redact(value: &str) -> String {
    static IDS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\b(org|user|proj|acct|account)[-_][A-Za-z0-9_-]{4,}")
            .expect("identifier regex")
    });
    static EMAIL: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}").expect("email regex")
    });
    EMAIL
        .replace_all(&IDS.replace_all(value, "[redacted]"), "[redacted]")
        .into_owned()
}

pub(crate) fn sanitized_error(value: Option<&JsonValue>) -> Option<JsonObject> {
    let value = value?;
    let mut result = JsonObject::new();
    let Some(fields) = value.as_object() else {
        result.insert("message", JsonValue::String(redact(value.as_str()?)));
        return Some(result);
    };
    for (key, value) in fields.iter() {
        match (key, value) {
            ("type" | "code" | "param" | "message" | "plan_type", JsonValue::String(value)) => {
                let end = value
                    .grapheme_indices(true)
                    .nth(4096)
                    .map_or(value.len(), |(offset, _)| offset);
                result.insert(key, JsonValue::String(redact(&value[..end])));
            }
            ("resets_at" | "resets_in_seconds", JsonValue::Number(_)) => {
                result.insert(key, value.clone());
            }
            _ => {}
        }
    }
    if let Some(retry_after) = retry_after_in(fields.get("headers")) {
        result.insert(
            "headers",
            object([("retry-after", JsonValue::String(retry_after.to_owned()))]),
        );
    }
    (!result.is_empty()).then_some(result)
}

/// Ordered public error fields for a JSON HTTP rejection.
pub fn error_envelope(
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    request_id: &str,
) -> JsonValue {
    object([(
        "error",
        JsonValue::Object(error_fields(error, provider, request_id)),
    )])
}

/// After SSE headers are submitted, provider failures get a terminal response envelope.
/// Transport errors use a standalone error event. Neither path appends a DONE frame.
pub fn stream_error_event(
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    request_id: &str,
) -> JsonValue {
    let mut fields = error_fields(error, provider, request_id);
    if fields.get("headers").is_none()
        && let Some(retry_after) = provider.and_then(|failure| failure.client_retry_after.as_ref())
    {
        fields.insert(
            "headers",
            object([("retry-after", JsonValue::String(retry_after.clone()))]),
        );
    }
    if provider.is_some_and(|failure| failure.provider_error.is_some()) {
        object([
            ("type", JsonValue::String("response.failed".into())),
            (
                "response",
                object([
                    ("status", JsonValue::String("failed".into())),
                    ("error", JsonValue::Object(fields)),
                ]),
            ),
        ])
    } else {
        object([
            ("type", JsonValue::String("error".into())),
            ("error", JsonValue::Object(fields)),
        ])
    }
}

fn error_fields(
    error: ProtocolError,
    provider: Option<&ProviderFailure>,
    request_id: &str,
) -> JsonObject {
    let mut fields = provider
        .and_then(|failure| failure.provider_error.clone())
        .unwrap_or_default();
    if fields.get("type").is_none() {
        let kind = if error.status < 500 {
            "invalid_request_error"
        } else {
            "server_error"
        };
        fields.insert("type", JsonValue::String(kind.into()));
    }
    if fields.get("code").is_none() {
        fields.insert("code", JsonValue::String(error.code.into()));
    }
    if fields.get("message").is_none() {
        let explanation = match error.code {
            "request_body_timeout" => {
                "The request upload did not finish in time. Check your connection or reduce conversation context and attached images before trying again. The request was not dispatched upstream."
            }
            "request_too_large" => {
                "Request body is too large. Reduce conversation context or attached images before trying again."
            }
            "model_not_allowed" => {
                "The selected model is not available for this request. Choose a model enabled for this operation and allowed by your API key."
            }
            "conversation_too_large" => {
                "The conversation or its images are too large. Start a new session or remove images before trying again."
            }
            "account_force_stopped" => {
                "An administrator stopped this account while the request was in progress. The upstream execution result may be unknown."
            }
            "continuation_owner_unavailable" => {
                "Continuation source cannot be verified. The request was not dispatched."
            }
            "unsupported_svg_model_selection" => {
                "Choosing an SVG author model is not supported. Omit the svg object to use the image endpoint default. The request was not dispatched."
            }
            _ => "Gateway request failed.",
        };
        let message = if is_uuid(request_id) {
            format!("{explanation} Reference: {request_id}.")
        } else {
            explanation.to_owned()
        };
        fields.insert("message", JsonValue::String(message));
    }
    fields.insert("request_id", JsonValue::String(request_id.into()));
    fields
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}
