use crate::Decimal;
use indexmap::IndexMap;
use std::{
    borrow::{Borrow, Cow},
    cmp::Ordering,
    error::Error,
    fmt,
    hash::{Hash, Hasher},
    io::Write,
    str,
};
use unicode_normalization::{UnicodeNormalization, is_nfc};

pub const MAX_JSON_DEPTH: usize = 64;

// JSONDecoder's independent structural cap also applies after UTF-16/32 transcoding.
const MAX_DECODER_DEPTH: usize = 512;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JsonError {
    InvalidJson,
    TooDeep,
}

impl JsonError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::InvalidJson => "invalid_json",
            Self::TooDeep => "json_too_deep",
        }
    }
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}

impl Error for JsonError {}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct JsonObject(IndexMap<Key, JsonValue>);

impl JsonObject {
    pub fn new() -> Self {
        Self::default()
    }

    /// Give a locally generated unordered map the same deterministic order as Swift.
    pub fn from_unordered(entries: impl IntoIterator<Item = (String, JsonValue)>) -> Self {
        let mut entries: Vec<_> = entries
            .into_iter()
            .map(|(key, value)| (Key::new(key), value))
            .collect();
        entries.sort_by(|(a, _), (b, _)| match a.as_ref().cmp(b.as_ref()) {
            Ordering::Equal => a.original.cmp(&b.original),
            order => order,
        });
        Self(entries.into_iter().collect())
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = (&str, &JsonValue)> {
        self.0
            .iter()
            .map(|(key, value)| (key.original.as_str(), value))
    }

    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        self.0.get(canonical(key).as_ref())
    }

    pub fn get_mut(&mut self, key: &str) -> Option<&mut JsonValue> {
        self.0.get_mut(canonical(key).as_ref())
    }

    /// Replace a member in place, or append it if absent.
    pub fn insert(&mut self, key: impl Into<String>, value: JsonValue) -> Option<JsonValue> {
        self.0.insert(Key::new(key.into()), value)
    }

    pub fn remove(&mut self, key: &str) -> Option<JsonValue> {
        self.0.shift_remove(canonical(key).as_ref())
    }

    pub fn retain(&mut self, mut keep: impl FnMut(&str, &JsonValue) -> bool) {
        self.0.retain(|key, value| keep(&key.original, value));
    }
}

// Swift String uses canonical equivalence. Keep the received spelling for wire output.
#[derive(Clone, Debug)]
struct Key {
    original: String,
    normalized: Option<String>,
}

impl Key {
    fn new(original: String) -> Self {
        let normalized = match canonical(&original) {
            Cow::Borrowed(_) => None,
            Cow::Owned(value) => Some(value),
        };
        Self {
            original,
            normalized,
        }
    }
}

impl AsRef<str> for Key {
    fn as_ref(&self) -> &str {
        self.normalized.as_deref().unwrap_or(&self.original)
    }
}

impl Borrow<str> for Key {
    fn borrow(&self) -> &str {
        self.as_ref()
    }
}

impl PartialEq for Key {
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl Eq for Key {}

impl Hash for Key {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.as_ref().hash(state);
    }
}

fn canonical(value: &str) -> Cow<'_, str> {
    if value.is_ascii() || is_nfc(value) {
        Cow::Borrowed(value)
    } else {
        Cow::Owned(value.nfc().collect())
    }
}

#[derive(Clone, Debug)]
pub enum JsonValue {
    Object(JsonObject),
    Array(Vec<JsonValue>),
    String(String),
    Number(Decimal),
    Bool(bool),
    Null,
}

impl PartialEq for JsonValue {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Object(a), Self::Object(b)) => a == b,
            (Self::Array(a), Self::Array(b)) => a == b,
            (Self::String(a), Self::String(b)) => a == b || canonical(a) == canonical(b),
            (Self::Number(a), Self::Number(b)) => a == b,
            (Self::Bool(a), Self::Bool(b)) => a == b,
            (Self::Null, Self::Null) => true,
            _ => false,
        }
    }
}

impl Eq for JsonValue {}

impl JsonValue {
    pub fn decode(bytes: &[u8]) -> Result<Self, JsonError> {
        Self::decode_rejecting_duplicates(bytes, &[])
    }

    /// Selected root keys (e.g. native Images controls) are unique. Other keys use first value.
    pub fn decode_rejecting_duplicates(
        bytes: &[u8],
        root_keys: &[&str],
    ) -> Result<Self, JsonError> {
        validate_depth(bytes)?;
        // Foundation recognizes this nonstandard UTF-32LE marker, but the Swift
        // order scanner falls back to sorted keys. Match that output while
        // checking selected root keys against the actual UTF-32LE document.
        let sorted_objects = bytes.starts_with(b"\xfe\xff\0\0");
        let normalized = normalize_encoding(bytes)?;
        let mut parser = Parser {
            remaining: normalized.as_ref(),
            root_keys,
            sorted_objects,
        };
        let value = parser.value(0, true)?;
        parser.whitespace();
        if !parser.remaining.is_empty() {
            return Err(JsonError::InvalidJson);
        }
        Ok(value)
    }

    pub fn as_object(&self) -> Option<&JsonObject> {
        match self {
            Self::Object(value) => Some(value),
            _ => None,
        }
    }

    pub fn as_object_mut(&mut self) -> Option<&mut JsonObject> {
        match self {
            Self::Object(value) => Some(value),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            Self::Array(value) => Some(value),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&Self> {
        self.as_object()?.get(key)
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(value) => Some(value),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Number(value) => value.as_i64(),
            _ => None,
        }
    }

    pub fn encode(&self, escaping_slashes: bool) -> Vec<u8> {
        let mut bytes = Vec::new();
        self.write(&mut bytes, escaping_slashes);
        bytes
    }

    fn write(&self, bytes: &mut Vec<u8>, escaping_slashes: bool) {
        match self {
            Self::Object(object) => {
                bytes.push(b'{');
                for (index, (key, value)) in object.iter().enumerate() {
                    if index != 0 {
                        bytes.push(b',');
                    }
                    write_string(bytes, key, escaping_slashes);
                    bytes.push(b':');
                    value.write(bytes, escaping_slashes);
                }
                bytes.push(b'}');
            }
            Self::Array(array) => {
                bytes.push(b'[');
                for (index, value) in array.iter().enumerate() {
                    if index != 0 {
                        bytes.push(b',');
                    }
                    value.write(bytes, escaping_slashes);
                }
                bytes.push(b']');
            }
            Self::String(value) => write_string(bytes, value, escaping_slashes),
            Self::Number(number) => {
                write!(bytes, "{number}").expect("writing to a Vec cannot fail")
            }
            Self::Bool(value) => bytes.extend_from_slice(if *value { b"true" } else { b"false" }),
            Self::Null => bytes.extend_from_slice(b"null"),
        }
    }
}

fn validate_depth(bytes: &[u8]) -> Result<(), JsonError> {
    // Keep the original preflight on received bytes, including its error precedence.
    let mut depth = 0_isize;
    let mut quoted = false;
    let mut escaped = false;
    for &byte in bytes {
        if escaped {
            escaped = false;
        } else if quoted {
            match byte {
                b'\\' => escaped = true,
                b'"' => quoted = false,
                _ => {}
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > MAX_JSON_DEPTH as isize {
                        return Err(JsonError::TooDeep);
                    }
                }
                b'}' | b']' => depth -= 1,
                _ => {}
            }
        }
    }
    Ok(())
}

fn normalize_encoding(bytes: &[u8]) -> Result<Cow<'_, [u8]>, JsonError> {
    let (width, little_endian, body) = match bytes {
        [0, 0, 0xfe, 0xff, rest @ ..] => (4, false, rest),
        // Foundation interprets the standard UTF-32LE BOM as UTF-16LE here.
        [0xff, 0xfe, 0, 0, ..] => return Err(JsonError::InvalidJson),
        [0xfe, 0xff, 0, 0, rest @ ..] => (4, true, rest),
        [0xfe, 0xff, rest @ ..] => (2, false, rest),
        [0xff, 0xfe, rest @ ..] => (2, true, rest),
        [0, 0, 0, first, ..] if *first != 0 => (4, false, bytes),
        [first, 0, 0, 0, ..] if *first != 0 => (4, true, bytes),
        [0, first, 0, second, ..] if *first != 0 && *second != 0 => (2, false, bytes),
        [first, 0, second, 0, ..] if *first != 0 && *second != 0 => (2, true, bytes),
        [0, first] if *first != 0 => (2, false, bytes),
        [first, 0] if *first != 0 => (2, true, bytes),
        _ => {
            return Ok(Cow::Borrowed(
                bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes),
            ));
        }
    };
    let chunks = bytes_chunks(body, width)?;
    let mut text = String::new();
    if width == 2 {
        let units = chunks.map(|chunk| {
            let unit = [chunk[0], chunk[1]];
            if little_endian {
                u16::from_le_bytes(unit)
            } else {
                u16::from_be_bytes(unit)
            }
        });
        for scalar in char::decode_utf16(units) {
            text.push(scalar.map_err(|_| JsonError::InvalidJson)?);
        }
    } else {
        for chunk in chunks {
            let unit = [chunk[0], chunk[1], chunk[2], chunk[3]];
            let scalar = if little_endian {
                u32::from_le_bytes(unit)
            } else {
                u32::from_be_bytes(unit)
            };
            text.push(char::from_u32(scalar).ok_or(JsonError::InvalidJson)?);
        }
    }
    Ok(Cow::Owned(text.into_bytes()))
}

fn bytes_chunks(bytes: &[u8], width: usize) -> Result<std::slice::ChunksExact<'_, u8>, JsonError> {
    let chunks = bytes.chunks_exact(width);
    if !chunks.remainder().is_empty() {
        return Err(JsonError::InvalidJson);
    }
    Ok(chunks)
}

struct Parser<'a, 'keys> {
    remaining: &'a [u8],
    root_keys: &'keys [&'keys str],
    sorted_objects: bool,
}

impl<'a> Parser<'a, '_> {
    fn value(&mut self, depth: usize, retain: bool) -> Result<JsonValue, JsonError> {
        self.whitespace();
        match self.remaining.first() {
            Some(b'{') if depth < MAX_DECODER_DEPTH => self.object(depth, retain),
            Some(b'[') if depth < MAX_DECODER_DEPTH => self.array(depth, retain),
            Some(b'"') => {
                let (token, escaped) = self.string_token()?;
                if retain {
                    Ok(JsonValue::String(decode_string(token, escaped)?))
                } else {
                    Ok(JsonValue::Null)
                }
            }
            Some(b't') if self.consume(b"true") => Ok(JsonValue::Bool(true)),
            Some(b'f') if self.consume(b"false") => Ok(JsonValue::Bool(false)),
            Some(b'n') if self.consume(b"null") => Ok(JsonValue::Null),
            Some(b'0'..=b'9' | b'-') => self.number(retain),
            _ => Err(JsonError::InvalidJson),
        }
    }

    fn object(&mut self, depth: usize, retain: bool) -> Result<JsonValue, JsonError> {
        self.remaining = &self.remaining[1..];
        let mut object = JsonObject::new();
        self.whitespace();
        while !self.consume(b"}") {
            let (token, escaped) = self.string_token()?;
            let key = if retain || !self.sorted_objects {
                let key = decode_string(token, escaped)?;
                retain.then(|| Key::new(key))
            } else {
                None
            };
            self.whitespace();
            if !self.consume(b":") {
                return Err(JsonError::InvalidJson);
            }

            if let Some(key) = key {
                if object.0.contains_key(key.as_ref()) {
                    if depth == 0
                        && self
                            .root_keys
                            .iter()
                            .any(|name| canonical(name) == key.as_ref())
                    {
                        return Err(JsonError::InvalidJson);
                    }
                    self.value(depth + 1, false)?;
                } else {
                    let value = self.value(depth + 1, true)?;
                    object.0.insert(key, value);
                }
            } else {
                // Scan discarded values for structure. Only the regular order
                // scan converts keys inside such values.
                self.value(depth + 1, false)?;
            }
            if self.end_or_comma(b"}")? {
                break;
            }
        }
        if self.sorted_objects {
            object
                .0
                .sort_unstable_by(|a, _, b, _| a.as_ref().cmp(b.as_ref()));
        }
        Ok(JsonValue::Object(object))
    }

    fn array(&mut self, depth: usize, retain: bool) -> Result<JsonValue, JsonError> {
        self.remaining = &self.remaining[1..];
        let mut array = Vec::new();
        self.whitespace();
        while !self.consume(b"]") {
            let value = self.value(depth + 1, retain)?;
            if retain {
                array.push(value);
            }
            if self.end_or_comma(b"]")? {
                break;
            }
        }
        Ok(JsonValue::Array(array))
    }

    fn end_or_comma(&mut self, close: &[u8]) -> Result<bool, JsonError> {
        self.whitespace();
        if self.consume(close) {
            return Ok(true);
        }
        if !self.consume(b",") {
            return Err(JsonError::InvalidJson);
        }
        // The baseline accepts a trailing comma in both arrays and objects.
        self.whitespace();
        Ok(false)
    }

    fn number(&mut self, retain: bool) -> Result<JsonValue, JsonError> {
        let length = self
            .remaining
            .iter()
            .take_while(|byte| matches!(byte, b'0'..=b'9' | b'+' | b'-' | b'.' | b'e' | b'E'))
            .count();
        let (token, rest) = self.remaining.split_at(length);
        self.remaining = rest;
        if retain {
            Decimal::parse(token)
                .map(JsonValue::Number)
                .ok_or(JsonError::InvalidJson)
        } else {
            Ok(JsonValue::Null)
        }
    }

    fn string_token(&mut self) -> Result<(&'a [u8], bool), JsonError> {
        if self.remaining.first() != Some(&b'"') {
            return Err(JsonError::InvalidJson);
        }
        let mut index = 1;
        let mut escaped = false;
        while let Some(byte) = self.remaining.get(index) {
            match byte {
                b'"' => {
                    let (token, rest) = self.remaining.split_at(index + 1);
                    self.remaining = rest;
                    return Ok((token, escaped));
                }
                b'\\' => {
                    escaped = true;
                    index += 2;
                }
                _ => index += 1,
            }
        }
        Err(JsonError::InvalidJson)
    }

    fn whitespace(&mut self) {
        while matches!(self.remaining.first(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.remaining = &self.remaining[1..];
        }
    }

    fn consume(&mut self, prefix: &[u8]) -> bool {
        if let Some(rest) = self.remaining.strip_prefix(prefix) {
            self.remaining = rest;
            true
        } else {
            false
        }
    }
}

fn decode_string(token: &[u8], escaped: bool) -> Result<String, JsonError> {
    if escaped {
        serde_json::from_slice(token).map_err(|_| JsonError::InvalidJson)
    } else {
        let text = &token[1..token.len() - 1];
        if text.iter().any(|byte| *byte < 32) {
            return Err(JsonError::InvalidJson);
        }
        Ok(str::from_utf8(text)
            .map_err(|_| JsonError::InvalidJson)?
            .to_owned())
    }
}

fn write_string(output: &mut Vec<u8>, value: &str, escaping_slashes: bool) {
    const HEX: &[u8] = b"0123456789abcdef";
    output.push(b'"');
    let mut start = 0;
    for (index, byte) in value.bytes().enumerate() {
        let escaped: &[u8] = match byte {
            b'"' => br#"\""#,
            b'\\' => br"\\",
            b'/' if escaping_slashes => br"\/",
            8 => br"\b",
            9 => br"\t",
            10 => br"\n",
            12 => br"\f",
            13 => br"\r",
            0..32 => &[
                b'\\',
                b'u',
                b'0',
                b'0',
                HEX[(byte / 16) as usize],
                HEX[(byte % 16) as usize],
            ],
            _ => continue,
        };
        output.extend_from_slice(&value.as_bytes()[start..index]);
        output.extend_from_slice(escaped);
        start = index + 1;
    }
    output.extend_from_slice(&value.as_bytes()[start..]);
    output.push(b'"');
}
