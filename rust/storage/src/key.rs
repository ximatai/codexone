use std::fmt;

use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidBearer;

impl fmt::Display for InvalidBearer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid bearer authorization")
    }
}

impl std::error::Error for InvalidBearer {}

/// Lowercase SHA-256 hex of the exact UTF-8 input stored in managed_keys.digest.
pub fn key_digest(value: &str) -> String {
    hex::encode(Sha256::digest(value))
}

/// Parse the managed-Key Authorization header before deriving its lookup digest.
pub fn bearer_digest(headers: &[&str]) -> Result<String, InvalidBearer> {
    let [header] = headers else {
        return Err(InvalidBearer);
    };
    let value = header.strip_prefix("Bearer ").ok_or(InvalidBearer)?;
    if !(24..=512).contains(&value.len()) || !value.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(InvalidBearer);
    }
    Ok(key_digest(value))
}
