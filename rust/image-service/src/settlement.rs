use std::time::{SystemTime, UNIX_EPOCH};

use codexone_execution::{Completeness, Failure, Outcome, PriceCompleteness, UsageEvidence};
use codexone_http_upstream::Instant;
use codexone_images::{
    ExecutionOutcome, ImageError, ImageEvidence, PriceCompleteness as ImagePrice, UsageCompleteness,
};

pub(crate) fn usage(usage: codexone_images::UsageEvidence) -> UsageEvidence {
    UsageEvidence {
        revision: usage.revision as i64,
        images: usage.images as i64,
        estimated_micros: usage.estimated_micros as i64,
        completeness: match usage.completeness {
            UsageCompleteness::Complete => Completeness::Complete,
            UsageCompleteness::Partial => Completeness::Partial,
        },
        price_completeness: Some(match usage.price_completeness {
            ImagePrice::Complete => PriceCompleteness::Complete,
            ImagePrice::Partial => PriceCompleteness::Partial,
            ImagePrice::Unavailable => PriceCompleteness::Unavailable,
        }),
        image_input_tokens: usage.image_input_tokens.map(|count| count as i64),
        image_output_tokens: usage.image_output_tokens.map(|count| count as i64),
        image_input_text_tokens: usage.image_input_text_tokens.map(|count| count as i64),
        image_input_image_tokens: usage.image_input_image_tokens.map(|count| count as i64),
        svg_input_tokens: usage.svg_input_tokens.map(|count| count as i64),
        svg_output_tokens: usage.svg_output_tokens.map(|count| count as i64),
        svg_reasoning_tokens: usage.svg_reasoning_tokens.map(|count| count as i64),
        svg_author_model: usage.svg_author_model,
        usage_missing_reasons: (!usage.missing_reasons.is_empty()).then(|| {
            usage
                .missing_reasons
                .into_iter()
                .map(str::to_owned)
                .collect()
        }),
        native_images: Some(true),
        provider_rejected_before_output: usage.provider_rejected_before_output.then_some(true),
        ..UsageEvidence::default()
    }
}

pub(crate) fn failure(error: &ImageError) -> Failure {
    match error.code {
        _ if error.cancelled => Failure::ClientCancelled,
        "account_force_stopped" => Failure::AccountUnavailable,
        "upstream_authentication_rejected" => Failure::AuthenticationRejected,
        "upstream_rate_limited" => Failure::RateLimited,
        "upstream_unavailable" => Failure::UpstreamUnavailable,
        "upstream_rejected" | "upstream_execution_failed" => Failure::UpstreamRejected,
        "execution_deadline_exceeded"
        | "execution_first_response_timeout"
        | "execution_progress_timeout" => Failure::DeadlineExceeded,
        "upstream_response_too_large" => Failure::InvalidUpstreamResponse,
        code if code.starts_with("invalid_upstream") => Failure::InvalidUpstreamResponse,
        _ if error.outcome == ExecutionOutcome::ProviderFailed => Failure::UpstreamRejected,
        _ => Failure::Indeterminate,
    }
}

pub(crate) fn outcome(
    failure: Option<Failure>,
    error: Option<&ImageError>,
    evidence: &ImageEvidence,
    started: Instant,
) -> Outcome {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(1, |value| {
            value.as_secs().clamp(1, 1_000_000_000_000) as i64
        });
    let millis = |at: Instant| at.saturating_duration_since(started).as_millis() as i64;
    let mut outcome = Outcome::new(failure, now);
    outcome.first_event_milliseconds = evidence.first_event_at.map(millis);
    outcome.total_milliseconds = Some(millis(Instant::now()));
    outcome.actual_service_tier = evidence.actual_service_tier.clone();
    if matches!(
        failure,
        Some(Failure::RateLimited | Failure::UpstreamUnavailable)
    ) {
        outcome.cooldown_seconds = error
            .and_then(|error| error.account_cooldown(now))
            .map(|s| s as i64);
    }
    outcome
}
