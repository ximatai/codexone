use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_http_upstream::CancellationToken;

use crate::{ExecutionOutcome, ImageError};

pub(crate) const MAX_IMAGE: usize = 16 * 1024 * 1024;
pub(crate) const MAX_IMAGES: usize = 16;
pub(crate) const MAX_TOTAL_IMAGES: usize = 24 * 1024 * 1024;

pub(crate) fn inline_size(url: &str, cancel: &CancellationToken) -> Result<usize, ImageError> {
    let (prefix, encoded) = url.split_once(',').ok_or_else(invalid)?;
    let media = match prefix {
        "data:image/png;base64" => "image/png",
        "data:image/jpeg;base64" => "image/jpeg",
        "data:image/webp;base64" => "image/webp",
        _ => return Err(invalid()),
    };
    if encoded.len() > MAX_IMAGE.div_ceil(3) * 4 {
        return Err(ImageError::input(413, "image_too_large"));
    }
    let bytes = STANDARD.decode(encoded).map_err(|_| invalid())?;
    raster_type(&bytes, Some(media), cancel)?;
    Ok(bytes.len())
}

pub(crate) fn raster_type(
    bytes: &[u8],
    declared: Option<&str>,
    cancel: &CancellationToken,
) -> Result<&'static str, ImageError> {
    if cancel.is_cancelled() {
        return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
    }
    if bytes.len() > MAX_IMAGE {
        return Err(ImageError::input(413, "image_too_large"));
    }
    let (media, (width, height)) = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        ("image/png", png(bytes, cancel)?)
    } else if bytes.starts_with(b"\xff\xd8") {
        ("image/jpeg", jpeg(bytes, cancel)?)
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        ("image/webp", webp(bytes, cancel)?)
    } else {
        return Err(ImageError::input(400, "unsupported_image_format"));
    };
    if !matches!(declared, None | Some("application/octet-stream")) && declared != Some(media)
        || !(1..=16_384).contains(&width)
        || !(1..=16_384).contains(&height)
        || width > 50_000_000 / height
    {
        return Err(ImageError::input(400, "invalid_image_dimensions"));
    }
    Ok(media)
}

fn invalid() -> ImageError {
    ImageError::input(400, "invalid_image")
}

fn animated() -> ImageError {
    ImageError::input(400, "animated_image_unsupported")
}

fn be(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .fold(0, |value, &byte| (value << 8) | usize::from(byte))
}

fn le(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .rev()
        .fold(0, |value, &byte| (value << 8) | usize::from(byte))
}

// Only inspect the container. Compressed pixels are never decoded.
fn png(mut bytes: &[u8], cancel: &CancellationToken) -> Result<(usize, usize), ImageError> {
    bytes = &bytes[8..];
    let mut dimensions = None;
    let mut color = 0;
    let mut palette = 0;
    let mut transparent = false;
    let mut seen_data = false;
    let mut ended_data = false;
    let mut data_bytes = 0;
    while bytes.len() >= 12 {
        let size = be(&bytes[..4]);
        if size > bytes.len() - 12 {
            return Err(invalid());
        }
        let (chunk, remainder) = bytes.split_at(size + 12);
        let tag = &chunk[4..8];
        let data = &chunk[8..8 + size];
        let mut crc = crc32fast::Hasher::new();
        for segment in chunk[4..8 + size].chunks(16 * 1024) {
            if cancel.is_cancelled() {
                return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
            }
            crc.update(segment);
        }
        if !tag.iter().all(u8::is_ascii_alphabetic)
            || !tag[2].is_ascii_uppercase()
            || crc.finalize() as usize != be(&chunk[8 + size..])
            || (dimensions.is_none() && tag != b"IHDR")
        {
            return Err(invalid());
        }
        match tag {
            b"IHDR" => {
                if dimensions.is_some() || size != 13 {
                    return Err(invalid());
                }
                color = data[9];
                let valid_depth = match color {
                    0 => matches!(data[8], 1 | 2 | 4 | 8 | 16),
                    2 | 4 | 6 => matches!(data[8], 8 | 16),
                    3 => matches!(data[8], 1 | 2 | 4 | 8),
                    _ => false,
                };
                if !valid_depth || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return Err(invalid());
                }
                dimensions = Some((be(&data[..4]), be(&data[4..8])));
            }
            b"PLTE" => {
                if seen_data
                    || palette != 0
                    || matches!(color, 0 | 4)
                    || !(1..=768).contains(&size)
                    || !size.is_multiple_of(3)
                {
                    return Err(invalid());
                }
                palette = size / 3;
            }
            b"tRNS" => {
                let valid = match color {
                    0 => size == 2,
                    2 => size == 6,
                    3 => (1..=palette).contains(&size),
                    _ => false,
                };
                if seen_data || transparent || !valid {
                    return Err(invalid());
                }
                transparent = true;
            }
            b"IDAT" => {
                if ended_data || (color == 3 && palette == 0) {
                    return Err(invalid());
                }
                seen_data = true;
                data_bytes += size;
            }
            b"IEND" if size == 0 && data_bytes > 0 && remainder.is_empty() => {
                return dimensions.ok_or_else(invalid);
            }
            b"IEND" => return Err(invalid()),
            b"acTL" | b"fcTL" | b"fdAT" => return Err(animated()),
            _ if tag[0].is_ascii_uppercase() => {
                return Err(ImageError::input(400, "unsupported_image_format"));
            }
            _ => {}
        }
        ended_data |= seen_data && tag != b"IDAT";
        bytes = remainder;
    }
    Err(invalid())
}

fn jpeg(bytes: &[u8], cancel: &CancellationToken) -> Result<(usize, usize), ImageError> {
    let bytes = bytes
        .strip_prefix(b"\xff\xd8")
        .and_then(|data| data.strip_suffix(b"\xff\xd9"))
        .ok_or_else(invalid)?;
    let mut offset = 0;
    let mut dimensions = None;
    while offset < bytes.len() {
        if cancel.is_cancelled() {
            return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
        }
        if bytes[offset] != 255 {
            return Err(invalid());
        }
        while bytes.get(offset) == Some(&255) {
            offset += 1;
        }
        let marker = *bytes.get(offset).ok_or_else(invalid)?;
        offset += 1;
        let size = be(bytes.get(offset..offset + 2).ok_or_else(invalid)?);
        if matches!(marker, 0 | 208..=217) || size < 2 || size > bytes.len() + 2 - offset {
            return Err(invalid());
        }
        if matches!(marker, 192..=194) {
            let frame = bytes.get(offset..offset + size).ok_or_else(invalid)?;
            if dimensions.is_some()
                || size < 8
                || frame[2] != 8
                || !(1..=4).contains(&frame[7])
                || size != 8 + usize::from(frame[7]) * 3
            {
                return Err(invalid());
            }
            dimensions = Some((be(&frame[5..7]), be(&frame[3..5])));
        }
        if marker == 218 {
            if size < 6 || offset + size >= bytes.len() {
                return Err(invalid());
            }
            return dimensions.ok_or_else(invalid);
        }
        offset += size;
    }
    Err(invalid())
}

fn webp(bytes: &[u8], cancel: &CancellationToken) -> Result<(usize, usize), ImageError> {
    if le(&bytes[4..8]) != bytes.len() - 8 {
        return Err(invalid());
    }
    let mut offset = 12;
    let mut canvas = None;
    let mut raster = None;
    while bytes.len() - offset >= 8 {
        if cancel.is_cancelled() {
            return Err(ImageError::cancelled(ExecutionOutcome::NotDispatched));
        }
        let size = le(&bytes[offset + 4..offset + 8]);
        let start = offset + 8;
        if size + size % 2 > bytes.len() - start {
            return Err(invalid());
        }
        let data = &bytes[start..start + size];
        match &bytes[offset..offset + 4] {
            b"VP8X" => {
                if offset != 12 || size != 10 || data[0] & 2 != 0 {
                    return Err(animated());
                }
                canvas = Some((le(&data[4..7]) + 1, le(&data[7..10]) + 1));
            }
            b"VP8 " => {
                if raster.is_some() || size < 10 || data[0] & 1 != 0 || data[3..6] != [157, 1, 42] {
                    return Err(invalid());
                }
                raster = Some((le(&data[6..8]) & 16383, le(&data[8..10]) & 16383));
            }
            b"VP8L" => {
                if raster.is_some() || size < 5 || data[0] != 47 {
                    return Err(invalid());
                }
                let packed = le(&data[1..5]);
                if packed >> 29 != 0 {
                    return Err(invalid());
                }
                raster = Some(((packed & 16383) + 1, ((packed >> 14) & 16383) + 1));
            }
            b"ANIM" | b"ANMF" => return Err(animated()),
            _ => {}
        }
        offset = start + size + size % 2;
    }
    if offset != bytes.len() || (canvas.is_some() && canvas != raster) {
        return Err(invalid());
    }
    raster.ok_or_else(invalid)
}

/// Canonical padded base64 with a nonempty decoded body, checked without allocating output.
pub(crate) fn canonical_base64(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return false;
    }
    let stripped = value.trim_end_matches('=').len();
    let padding = bytes.len() - stripped;
    if padding > 2 {
        return false;
    }
    fn digit(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    bytes[..stripped].iter().all(|&byte| digit(byte).is_some())
        && (padding == 0
            || digit(bytes[stripped - 1])
                .is_some_and(|last| last & (if padding == 1 { 3 } else { 15 }) == 0))
}
