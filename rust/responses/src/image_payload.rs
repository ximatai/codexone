use crate::ProtocolError;
use base64::{Engine, engine::general_purpose::STANDARD};

const IMAGE_BYTES: usize = 16_777_216;
const INVALID: ProtocolError = ProtocolError::new(400, "invalid_image");
const UNSUPPORTED: ProtocolError = ProtocolError::new(400, "unsupported_image_format");
const ANIMATED: ProtocolError = ProtocolError::new(400, "animated_image_unsupported");
const TOO_LARGE: ProtocolError = ProtocolError::new(413, "image_too_large");

pub(crate) fn validate_mask(input: &str, mask: &str) -> Result<(), ProtocolError> {
    let (_, (width, height, _)) = inspect_data_url(input)?;
    let (media, (mask_width, mask_height, alpha)) = inspect_data_url(mask)?;
    if media != "image/png" || !alpha || (width, height) != (mask_width, mask_height) {
        return Err(ProtocolError::new(400, "invalid_image_mask"));
    }
    Ok(())
}

type ImageInfo = (u32, u32, bool);

fn inspect_data_url(url: &str) -> Result<(&'static str, ImageInfo), ProtocolError> {
    let Some((prefix, encoded)) = url.split_once(',') else {
        return Err(INVALID);
    };
    let declared = match prefix {
        "data:image/png;base64" => "image/png",
        "data:image/jpeg;base64" => "image/jpeg",
        "data:image/webp;base64" => "image/webp",
        _ => return Err(INVALID),
    };
    if encoded.len() > IMAGE_BYTES.div_ceil(3) * 4 {
        return Err(TOO_LARGE);
    }
    let bytes = STANDARD.decode(encoded).map_err(|_| INVALID)?;
    if bytes.len() > IMAGE_BYTES {
        return Err(TOO_LARGE);
    }
    let (media, info) = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        ("image/png", png(&bytes)?)
    } else if bytes.starts_with(b"\xff\xd8") {
        ("image/jpeg", jpeg(&bytes)?)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        ("image/webp", webp(&bytes)?)
    } else {
        return Err(UNSUPPORTED);
    };
    let (width, height, _) = info;
    if media != declared
        || !(1..=16384).contains(&width)
        || !(1..=16384).contains(&height)
        || width > 50_000_000 / height
    {
        return Err(ProtocolError::new(400, "invalid_image_dimensions"));
    }
    Ok((media, info))
}

fn be32(bytes: &[u8]) -> u32 {
    u32::from_be_bytes(bytes[..4].try_into().expect("four bytes"))
}

fn be16(bytes: &[u8]) -> u32 {
    u16::from_be_bytes(bytes[..2].try_into().expect("two bytes")).into()
}

fn le(bytes: &[u8]) -> u32 {
    let mut value = [0; 4];
    value[..bytes.len()].copy_from_slice(bytes);
    u32::from_le_bytes(value)
}

fn png(mut bytes: &[u8]) -> Result<ImageInfo, ProtocolError> {
    bytes = &bytes[8..];
    let mut header = None;
    let mut idat_bytes = 0;
    let mut idat_seen = false;
    let mut idat_ended = false;
    let mut palette = 0;
    let mut color = 0;
    let mut transparency = false;
    while bytes.len() >= 12 {
        let size = be32(bytes) as usize;
        if size > bytes.len() - 12 {
            return Err(INVALID);
        }
        let kind = &bytes[4..8];
        let data = &bytes[8..8 + size];
        if !kind.iter().all(u8::is_ascii_alphabetic)
            || !kind[2].is_ascii_uppercase()
            || crc32fast::hash(&bytes[4..8 + size]) != be32(&bytes[8 + size..])
            || (header.is_none() && kind != b"IHDR")
        {
            return Err(INVALID);
        }
        match kind {
            b"IHDR" => {
                if header.is_some() || size != 13 {
                    return Err(INVALID);
                }
                color = data[9];
                let depths: &[u8] = match color {
                    0 => &[1, 2, 4, 8, 16],
                    2 | 4 | 6 => &[8, 16],
                    3 => &[1, 2, 4, 8],
                    _ => &[],
                };
                if !depths.contains(&data[8]) || data[10] != 0 || data[11] != 0 || data[12] > 1 {
                    return Err(INVALID);
                }
                header = Some((be32(data), be32(&data[4..])));
            }
            b"PLTE" => {
                if idat_seen
                    || palette != 0
                    || matches!(color, 0 | 4)
                    || size == 0
                    || size > 768
                    || !size.is_multiple_of(3)
                {
                    return Err(INVALID);
                }
                palette = size / 3;
            }
            b"tRNS" => {
                let valid = (color == 0 && size == 2)
                    || (color == 2 && size == 6)
                    || (color == 3 && (1..=palette).contains(&size));
                if !valid || idat_seen || transparency {
                    return Err(INVALID);
                }
                transparency = true;
            }
            b"IDAT" => {
                if idat_ended || (color == 3 && palette == 0) {
                    return Err(INVALID);
                }
                idat_seen = true;
                idat_bytes += size;
            }
            b"IEND" => {
                if size != 0 || idat_bytes == 0 || bytes.len() != 12 {
                    return Err(INVALID);
                }
                let (width, height) = header.expect("first chunk is the header");
                return Ok((width, height, transparency || matches!(color, 4 | 6)));
            }
            b"acTL" | b"fcTL" | b"fdAT" => return Err(ANIMATED),
            _ if kind[0].is_ascii_uppercase() => return Err(UNSUPPORTED),
            _ => {}
        }
        idat_ended |= idat_seen && kind != b"IDAT";
        bytes = &bytes[12 + size..];
    }
    Err(INVALID)
}

fn jpeg(mut bytes: &[u8]) -> Result<ImageInfo, ProtocolError> {
    if bytes.len() < 4 || !bytes.ends_with(b"\xff\xd9") {
        return Err(INVALID);
    }
    bytes = &bytes[2..];
    let mut dimensions = None;
    while bytes.len() > 2 {
        if bytes[0] != 255 {
            return Err(INVALID);
        }
        let Some(marker_offset) = bytes.iter().position(|&b| b != 255) else {
            return Err(INVALID);
        };
        let marker = bytes[marker_offset];
        bytes = &bytes[marker_offset + 1..];
        if matches!(marker, 0 | 208..=217) || bytes.len() < 2 {
            return Err(INVALID);
        }
        let size = be16(bytes) as usize;
        if size < 2 || size > bytes.len() {
            return Err(INVALID);
        }
        if matches!(marker, 192..=194) {
            if dimensions.is_some()
                || size < 8
                || bytes[2] != 8
                || !(1..=4).contains(&bytes[7])
                || size != 8 + usize::from(bytes[7]) * 3
            {
                return Err(INVALID);
            }
            dimensions = Some((be16(&bytes[5..]), be16(&bytes[3..]), false));
        }
        if marker == 218 {
            if size < 6 || size + 2 >= bytes.len() {
                return Err(INVALID);
            }
            return dimensions.ok_or(INVALID);
        }
        bytes = &bytes[size..];
    }
    Err(INVALID)
}

fn webp(mut bytes: &[u8]) -> Result<ImageInfo, ProtocolError> {
    if le(&bytes[4..8]) as usize != bytes.len() - 8 {
        return Err(INVALID);
    }
    bytes = &bytes[12..];
    let mut first_chunk = true;
    let mut canvas = None;
    let mut raster = None;
    while bytes.len() >= 8 {
        let kind = &bytes[..4];
        let size = le(&bytes[4..8]) as usize;
        if size > bytes.len() - 8 {
            return Err(INVALID);
        }
        let data = &bytes[8..8 + size];
        match kind {
            b"VP8X" => {
                if !first_chunk || size != 10 || data[0] & 2 != 0 {
                    return Err(ANIMATED);
                }
                canvas = Some((le(&data[4..7]) + 1, le(&data[7..10]) + 1, data[0] & 16 != 0));
            }
            b"VP8 " => {
                if raster.is_some() || size < 10 || data[0] & 1 != 0 || data[3..6] != [157, 1, 42] {
                    return Err(INVALID);
                }
                raster = Some((
                    le(&data[6..8]) & 16383,
                    le(&data[8..10]) & 16383,
                    canvas.is_some_and(|(_, _, alpha)| alpha),
                ));
            }
            b"VP8L" => {
                if raster.is_some() || size < 5 || data[0] != 47 {
                    return Err(INVALID);
                }
                let packed = le(&data[1..5]);
                if packed >> 29 != 0 {
                    return Err(INVALID);
                }
                raster = Some((
                    (packed & 16383) + 1,
                    ((packed >> 14) & 16383) + 1,
                    packed & (1 << 28) != 0,
                ));
            }
            b"ANIM" | b"ANMF" => return Err(ANIMATED),
            _ => {}
        }
        first_chunk = false;
        bytes = bytes.get(8 + size + size % 2..).ok_or(INVALID)?;
    }
    let (width, height, alpha) = raster.ok_or(INVALID)?;
    if !bytes.is_empty()
        || canvas.is_some_and(|(canvas_width, canvas_height, _)| {
            (width, height) != (canvas_width, canvas_height)
        })
    {
        return Err(INVALID);
    }
    Ok((width, height, alpha))
}
