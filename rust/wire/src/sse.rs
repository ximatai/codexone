use crate::JsonValue;
use memchr::memchr_iter;
use std::{borrow::Cow, error::Error, fmt, iter, str};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SseError {
    ResponseTooLarge,
    EventTooLarge,
    InvalidEvent,
    IncompleteEvent,
}

impl SseError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::ResponseTooLarge => "upstream_response_too_large",
            Self::EventTooLarge => "upstream_event_too_large",
            Self::InvalidEvent => "invalid_upstream_event",
            Self::IncompleteEvent => "incomplete_upstream_event",
        }
    }
}

impl fmt::Display for SseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}

impl Error for SseError {}

#[derive(Debug, Eq, PartialEq)]
pub enum SsePayload {
    Json(JsonValue),
    Done,
    Ignored,
}

#[derive(Debug, Eq, PartialEq)]
pub struct SseFrame<'a> {
    /// Exact bytes, including comments, field lines and the terminating blank line.
    pub raw: &'a [u8],
    pub payload: SsePayload,
}

#[derive(Debug)]
pub struct SseDecoder {
    max_event_bytes: usize,
    max_total_bytes: usize,
    total: usize,
    buffer: Vec<u8>,
    at_boundary: bool,
    saw_done: bool,
}

impl Default for SseDecoder {
    fn default() -> Self {
        Self::new(262_144, 8_388_608)
    }
}

impl SseDecoder {
    /// The caller supplies limits for its HTTP route. The cumulative limit includes framing.
    pub fn new(max_event_bytes: usize, max_total_bytes: usize) -> Self {
        Self {
            max_event_bytes,
            max_total_bytes,
            total: 0,
            buffer: Vec::new(),
            at_boundary: true,
            saw_done: false,
        }
    }

    pub fn is_at_event_boundary(&self) -> bool {
        self.at_boundary
    }

    pub fn saw_done(&self) -> bool {
        self.saw_done
    }

    /// Consume at most one frame from this chunk. On success with a frame, handle it before
    /// calling again on the unconsumed suffix. A later framing error cannot erase prior evidence.
    /// Stop consuming the stream after an error.
    pub fn next_frame(&mut self, chunk: &mut &[u8]) -> Result<Option<SseFrame<'_>>, SseError> {
        if chunk.is_empty() {
            return Ok(None);
        }
        let total_room = self.max_total_bytes - self.total;
        if total_room == 0 {
            return Err(SseError::ResponseTooLarge);
        }
        if self.at_boundary {
            self.buffer.clear();
            self.at_boundary = false;
        }

        // The previous decoder allowed four framing bytes, then consumed one
        // more byte before reporting an unterminated event over that bound.
        let event_ceiling = self.max_event_bytes.saturating_add(4);
        let event_room = event_ceiling.saturating_sub(self.buffer.len());
        let scan_length = chunk
            .len()
            .min(total_room)
            .min(event_room.saturating_add(1));
        let scanned = &chunk[..scan_length];
        let delimiter = find_delimiter(&self.buffer, scanned);
        let consumed = delimiter.map_or(scan_length, |(end, _)| end);
        self.buffer.extend_from_slice(&chunk[..consumed]);
        *chunk = &chunk[consumed..];
        self.total += consumed;

        let Some((_, delimiter_length)) = delimiter else {
            if self.buffer.len() > event_ceiling {
                return Err(SseError::EventTooLarge);
            }
            if !chunk.is_empty() {
                return Err(SseError::ResponseTooLarge);
            }
            return Ok(None);
        };
        let length = self.buffer.len() - delimiter_length;
        if length > self.max_event_bytes {
            return Err(SseError::EventTooLarge);
        }
        let text = str::from_utf8(&self.buffer[..length]).map_err(|_| SseError::InvalidEvent)?;
        self.at_boundary = true;
        let payload = self.decode_payload(text)?;
        self.saw_done |= matches!(payload, SsePayload::Done);
        Ok(Some(SseFrame {
            raw: &self.buffer,
            payload,
        }))
    }

    /// EOF requires a frame boundary. Protocol-specific terminal evidence is checked by the caller.
    pub fn finish(&self) -> Result<(), SseError> {
        if self.at_boundary {
            Ok(())
        } else {
            Err(SseError::IncompleteEvent)
        }
    }

    fn decode_payload(&self, text: &str) -> Result<SsePayload, SseError> {
        let normalized = if text.contains("\r\n") {
            Cow::Owned(text.replace("\r\n", "\n"))
        } else {
            Cow::Borrowed(text)
        };
        let text = normalized.as_ref();
        let mut start = 0;
        let mut data = text
            .match_indices('\n')
            // Linux Swift splits on LF Characters. After the one-pass normalization,
            // a literal CRCRLF becomes a CRLF Character and stays on the same line.
            .filter_map(|(end, _)| (!text[..end].ends_with('\r')).then_some(end))
            .chain(iter::once(text.len()))
            .filter_map(|end| {
                let line = &text[start..end];
                start = end + 1;
                let line = line.strip_suffix('\r').unwrap_or(line);
                let value = strip_grapheme_prefix(line, "data:")?;
                Some(strip_grapheme_prefix(value, " ").unwrap_or(value))
            });
        let first = data.next().unwrap_or("");
        let assembled;
        let payload = match data.next() {
            Some(second) => {
                let mut joined = String::with_capacity(first.len() + second.len() + 1);
                joined.push_str(first);
                joined.push('\n');
                joined.push_str(second);
                for line in data {
                    joined.push('\n');
                    joined.push_str(line);
                }
                assembled = joined;
                assembled.as_str()
            }
            None => first,
        };
        if payload.is_empty() {
            return Ok(SsePayload::Ignored);
        }
        if self.saw_done {
            return Err(SseError::InvalidEvent);
        }
        if payload == "[DONE]" {
            return Ok(SsePayload::Done);
        }
        JsonValue::decode(payload.as_bytes())
            .map(SsePayload::Json)
            .map_err(|_| SseError::InvalidEvent)
    }
}

fn find_delimiter(previous: &[u8], chunk: &[u8]) -> Option<(usize, usize)> {
    for newline in memchr_iter(b'\n', chunk) {
        let end = newline + 1;
        // The terminal LF is accounted for by memchr. Test the preceding
        // bytes in the chunk, borrowing the prior frame suffix across a split.
        let before_lf = &chunk[..newline];
        if ends_with(previous, before_lf, b"\r\n\r") {
            return Some((end, 4));
        }
        if ends_with(previous, before_lf, b"\n") {
            return Some((end, 2));
        }
    }
    None
}

fn ends_with(previous: &[u8], prefix: &[u8], suffix: &[u8]) -> bool {
    if prefix.len() >= suffix.len() {
        return prefix.ends_with(suffix);
    }
    let (earlier, later) = suffix.split_at(suffix.len() - prefix.len());
    prefix == later && previous.ends_with(earlier)
}

// Swift's hasPrefix/dropFirst count Characters. ASCII separators immediately
// followed by a non-ASCII combining mark may belong to a single Character.
fn strip_grapheme_prefix<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let rest = text.strip_prefix(prefix)?;
    if rest.as_bytes().first().is_none_or(u8::is_ascii) {
        return Some(rest);
    }
    let last = &text[prefix.len() - 1..];
    (last.graphemes(true).next()?.len() == 1).then_some(rest)
}
