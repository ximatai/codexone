//! Responses protocol validation and provider evidence. Callers own admission, I/O and settlement.

mod events;
mod image_payload;
mod provider_error;
mod request;
mod usage;

pub use codexone_wire::{JsonObject, JsonValue};
pub use events::*;
pub use provider_error::*;
pub use request::*;
pub use usage::*;

use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProtocolError {
    pub status: u16,
    pub code: &'static str,
    pub detail: Option<&'static str>,
}

impl ProtocolError {
    pub const fn new(status: u16, code: &'static str) -> Self {
        Self {
            status,
            code,
            detail: None,
        }
    }

    pub const fn with_detail(self, detail: &'static str) -> Self {
        Self {
            detail: Some(detail),
            ..self
        }
    }
}

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code)
    }
}

impl std::error::Error for ProtocolError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BindingKind {
    Response,
    Item,
    FunctionCall,
    Compaction,
    ReasoningContext,
    CompactionContext,
}

impl BindingKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Response => "response",
            Self::Item => "item",
            Self::FunctionCall => "function_call",
            Self::Compaction => "compaction",
            Self::ReasoningContext => "context_reasoning",
            Self::CompactionContext => "context_compaction",
        }
    }
}

#[derive(Clone, Debug, Eq)]
pub struct ObjectBinding {
    pub kind: BindingKind,
    pub raw_id: String,
}

impl ObjectBinding {
    fn new(kind: BindingKind, raw_id: impl Into<String>) -> Self {
        Self {
            kind,
            raw_id: raw_id.into(),
        }
    }
}

impl PartialEq for ObjectBinding {
    fn eq(&self, other: &Self) -> bool {
        self.kind == other.kind && same_text(&self.raw_id, &other.raw_id)
    }
}

fn same_text(lhs: &str, rhs: &str) -> bool {
    lhs == rhs || (!(lhs.is_ascii() && rhs.is_ascii()) && lhs.nfc().eq(rhs.nfc()))
}

fn valid_id(value: &JsonValue) -> Option<&str> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 256)
}

fn opaque_context(item_type: &str, value: &JsonValue) -> Option<ObjectBinding> {
    let kind = match item_type {
        "reasoning" => BindingKind::ReasoningContext,
        "compaction" => BindingKind::CompactionContext,
        _ => return None,
    };
    let encrypted = value
        .as_str()
        .filter(|text| !text.is_empty() && text.len() <= 196_608)?;
    Some(ObjectBinding::new(
        kind,
        hex::encode(Sha256::digest(encrypted.as_bytes())),
    ))
}

fn text<'a>(value: &'a JsonValue, member: &str) -> Option<&'a str> {
    value.get(member)?.as_str()
}

fn metadata(value: Option<&JsonValue>) -> Option<String> {
    let valid = value?.as_str().filter(|s| {
        (1..=32).contains(&s.len())
            && s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    });
    Some(valid.unwrap_or("other").to_owned())
}

fn object(fields: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    let mut object = JsonObject::new();
    for (key, value) in fields {
        object.insert(key, value);
    }
    JsonValue::Object(object)
}
