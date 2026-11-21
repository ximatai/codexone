use std::borrow::Cow;
use std::fmt;

use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};
use serde_json::value::RawValue;
use serde_json::{Map, Value};

pub(crate) fn decode(bytes: &[u8], limit: usize) -> Option<Value> {
    let text = utf8(bytes)?;
    let text = without_trailing_commas(&text);
    read_value(serde_json::from_str(&text).ok()?, limit)
}

fn utf8(bytes: &[u8]) -> Option<Cow<'_, str>> {
    // JSONDecoder recognizes both byte-order marks and the leading ASCII
    // JSON token's byte pattern when a UTF-16/32 document has no mark.
    let (data, width, little_endian) = match bytes {
        [0xff, 0xfe, 0, 0, data @ ..] => (data, 4, true),
        [0, 0, 0xfe, 0xff, data @ ..] => (data, 4, false),
        [0xff, 0xfe, data @ ..] => (data, 2, true),
        [0xfe, 0xff, data @ ..] => (data, 2, false),
        [0, 0, 0, _, ..] => (bytes, 4, false),
        [_, 0, 0, 0, ..] => (bytes, 4, true),
        [0, _, 0, _, ..] => (bytes, 2, false),
        [_, 0, _, 0, ..] => (bytes, 2, true),
        [0xef, 0xbb, 0xbf, data @ ..] => {
            return Some(Cow::Borrowed(std::str::from_utf8(data).ok()?));
        }
        _ => return Some(Cow::Borrowed(std::str::from_utf8(bytes).ok()?)),
    };
    let text = if width == 2 {
        let (chunks, []) = data.as_chunks::<2>() else {
            return None;
        };
        let code_units = chunks.iter().copied().map(|bytes| {
            if little_endian {
                u16::from_le_bytes(bytes)
            } else {
                u16::from_be_bytes(bytes)
            }
        });
        char::decode_utf16(code_units)
            .collect::<Result<String, _>>()
            .ok()?
    } else {
        let (chunks, []) = data.as_chunks::<4>() else {
            return None;
        };
        chunks
            .iter()
            .copied()
            .map(|bytes| {
                char::from_u32(if little_endian {
                    u32::from_le_bytes(bytes)
                } else {
                    u32::from_be_bytes(bytes)
                })
            })
            .collect::<Option<String>>()?
    };
    Some(Cow::Owned(text))
}

/// Swift JSON decoding accepts one trailing comma after an object member or array element.
pub(crate) fn without_trailing_commas(text: &str) -> Cow<'_, str> {
    let mut rewritten = None::<String>;
    let mut start = 0;
    let mut previous = b' ';
    let mut quoted = false;
    let mut escaped = false;
    for (index, byte) in text.bytes().enumerate() {
        if quoted {
            if escaped {
                escaped = false;
            } else {
                match byte {
                    b'\\' => escaped = true,
                    b'"' => {
                        quoted = false;
                        previous = byte;
                    }
                    _ => {}
                }
            }
            continue;
        }
        match byte {
            b'"' => quoted = true,
            b',' if !matches!(previous, b'{' | b'[' | b',' | b':')
                && text[index + 1..]
                    .trim_start_matches([' ', '\n', '\r', '\t'])
                    .starts_with([']', '}']) =>
            {
                rewritten
                    .get_or_insert_with(|| String::with_capacity(text.len()))
                    .push_str(&text[start..index]);
                start = index + 1;
                previous = byte;
            }
            b' ' | b'\n' | b'\r' | b'\t' => {}
            _ => previous = byte,
        }
    }
    if let Some(mut result) = rewritten {
        result.push_str(&text[start..]);
        Cow::Owned(result)
    } else {
        Cow::Borrowed(text)
    }
}

fn read_value(raw: &RawValue, remaining: usize) -> Option<Value> {
    let text = raw.get();
    match text.as_bytes().first()? {
        b'{' => {
            let fields: FirstFields<'_> = serde_json::from_str(text).ok()?;
            let remaining = remaining.checked_sub(1)?;
            let mut object = Map::with_capacity(fields.0.len());
            for (key, raw) in fields.0 {
                object.insert(key, read_value(raw, remaining)?);
            }
            Some(Value::Object(object))
        }
        b'[' => {
            let remaining = remaining.checked_sub(1)?;
            let fields: Vec<&RawValue> = serde_json::from_str(text).ok()?;
            fields
                .into_iter()
                .map(|value| read_value(value, remaining))
                .collect::<Option<Vec<_>>>()
                .map(Value::Array)
        }
        _ => serde_json::from_str(text).ok(),
    }
}

/// Swift's keyed decoding sees the first value for a repeated JSON key.
pub(crate) struct FirstFields<'a>(pub(crate) indexmap::IndexMap<String, &'a RawValue>);

impl<'de> Deserialize<'de> for FirstFields<'de> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct FirstFieldsVisitor;
        impl<'de> Visitor<'de> for FirstFieldsVisitor {
            type Value = FirstFields<'de>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a JSON object")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<Self::Value, A::Error> {
                let mut fields = indexmap::IndexMap::new();
                while let Some((key, value)) = access.next_entry::<String, &'de RawValue>()? {
                    fields.entry(key).or_insert(value);
                }
                Ok(FirstFields(fields))
            }
        }
        deserializer.deserialize_map(FirstFieldsVisitor)
    }
}
