//! Native Images HTTP request and response adapter. The data service owns Key authorization,
//! durable admission, account routing, ingress body leases and finalization.

mod capacity;
mod failure;
mod payload;
mod request;
mod response;
mod usage;

pub use capacity::{ImageCapacity, ImagePermit};
pub use failure::{ExecutionOutcome, ImageError};
pub use request::{ImageEndpoint, ImageRequest, ImageRoute, MAX_REQUEST_BYTES};
pub use response::{ImageExchange, ImageOutput, MAX_RESPONSE_BYTES};
pub use usage::{
    ImageEvidence, ImageRates, PriceCompleteness, TokenRates, UsageCompleteness, UsageEvidence,
};

fn metadata(value: Option<&codexone_wire::JsonValue>) -> Option<String> {
    value.map(|value| {
        value
            .as_str()
            .filter(|text| {
                (1..=32).contains(&text.len())
                    && text.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_-".contains(&byte)
                    })
            })
            .unwrap_or("other")
            .to_owned()
    })
}

fn connection_names(headers: &http::HeaderMap) -> impl Iterator<Item = &str> {
    headers
        .get_all(http::header::CONNECTION)
        .iter()
        .filter_map(|value| std::str::from_utf8(value.as_bytes()).ok())
        .flat_map(|value| value.split(',').map(str::trim))
}

fn valid_turn_state(value: &[u8]) -> bool {
    !value.is_empty()
        && value.len() <= 8192
        && value
            .iter()
            .all(|&byte| byte == 9 || (byte >= 32 && byte != 127))
        && std::str::from_utf8(value).is_ok()
}
