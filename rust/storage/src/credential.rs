use std::fmt;
use std::path::Path;

use aes_gcm::aead::{AeadInPlace, KeyInit, OsRng, rand_core::RngCore};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::{files::private_data, key_digest};

const MAX_ENVELOPE: usize = 49_152;
const MAX_PLAINTEXT: usize = 33_000;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
const MAX_TIMESTAMP: i64 = 1_000_000_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CredentialError;

impl fmt::Display for CredentialError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid account credential, context, or encryption key")
    }
}

impl std::error::Error for CredentialError {}

/// Ephemeral plaintext. Serialization is private to the encrypted envelope.
pub struct AccountCredential(Payload);

impl AccountCredential {
    pub fn new(
        access_token: String,
        refresh_token: String,
        id_token: Option<String>,
        expires_at_unix_seconds: i64,
    ) -> Result<Self, CredentialError> {
        Self::from_payload(Payload {
            access_token,
            refresh_token,
            id_token,
            expires_at_unix_seconds,
        })
    }

    fn from_payload(payload: Payload) -> Result<Self, CredentialError> {
        let tokens = [&payload.access_token, &payload.refresh_token]
            .into_iter()
            .chain(payload.id_token.as_ref());
        if !tokens.clone().all(|token| {
            (1..=16_384).contains(&token.len())
                && token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-._~+/=".contains(&b))
        }) || tokens.map(String::len).sum::<usize>() > 32_768
            || !(1..=MAX_TIMESTAMP).contains(&payload.expires_at_unix_seconds)
        {
            return Err(CredentialError);
        }
        Ok(Self(payload))
    }

    pub fn access_token(&self) -> &str {
        &self.0.access_token
    }

    pub fn refresh_token(&self) -> &str {
        &self.0.refresh_token
    }

    pub fn id_token(&self) -> Option<&str> {
        self.0.id_token.as_deref()
    }

    pub fn expires_at_unix_seconds(&self) -> i64 {
        self.0.expires_at_unix_seconds
    }
}

impl fmt::Debug for AccountCredential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AccountCredential(redacted)")
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Payload {
    access_token: String,
    refresh_token: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    id_token: Option<String>,
    expires_at_unix_seconds: i64,
}

impl Drop for Payload {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
        self.id_token.zeroize();
    }
}

pub struct AccountCredentialContext<'a> {
    identity: &'a str,
    namespace: &'a str,
    version: i64,
}

impl<'a> AccountCredentialContext<'a> {
    pub fn new(
        identity: &'a str,
        namespace: &'a str,
        version: i64,
    ) -> Result<Self, CredentialError> {
        if !(1..=64).contains(&identity.len())
            || !(1..=512).contains(&namespace.len())
            || !identity
                .bytes()
                .chain(namespace.bytes())
                .all(|byte| byte.is_ascii_graphic())
            || !(1..=1_000_000).contains(&version)
        {
            return Err(CredentialError);
        }
        Ok(Self {
            identity,
            namespace,
            version,
        })
    }

    fn aad(&self, key_id: &str) -> Result<String, CredentialError> {
        let encoded = serde_json::to_string(&[
            "codexone.account-credential",
            "1",
            key_id,
            self.identity,
            self.namespace,
            &self.version.to_string(),
        ])
        .map_err(|_| CredentialError)?;
        // Swift's AAD encoder uses Foundation's default escaping for slashes.
        Ok(encoded.replace('/', "\\/"))
    }
}

/// One active AES-256-GCM key and up to seven decrypt-only keys.
pub struct AccountCredentialCipher {
    active: Key,
    decrypt_only: Vec<Key>,
}

impl fmt::Debug for AccountCredentialCipher {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AccountCredentialCipher(redacted)")
    }
}

struct Key {
    id: String,
    material: Zeroizing<[u8; 32]>,
}

impl Key {
    fn from_hex(hex_key: &str) -> Result<Self, CredentialError> {
        let mut material = Zeroizing::new([0; 32]);
        hex::decode_to_slice(hex_key, material.as_mut()).map_err(|_| CredentialError)?;
        Ok(Self::from_material(material))
    }

    fn from_material(material: Zeroizing<[u8; 32]>) -> Self {
        let id = hex::encode(&Sha256::digest(material.as_ref())[..16]);
        Self { id, material }
    }

    fn cipher(&self) -> Aes256Gcm {
        Aes256Gcm::new(self.material.as_ref().into())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Keyring {
    format: f64,
    active: String,
    decrypt_only: Vec<String>,
}

impl Drop for Keyring {
    fn drop(&mut self) {
        self.active.zeroize();
        self.decrypt_only.zeroize();
    }
}

impl AccountCredentialCipher {
    pub fn from_hex(
        active_hex_key: &str,
        decrypt_only_hex_keys: &[&str],
    ) -> Result<Self, CredentialError> {
        if decrypt_only_hex_keys.len() > 7 {
            return Err(CredentialError);
        }
        Self::from_keys(
            Key::from_hex(active_hex_key)?,
            decrypt_only_hex_keys.iter().map(|key| Key::from_hex(key)),
        )
    }

    /// Build the cipher from previously validated configuration key material.
    pub fn from_key_bytes(
        active: &[u8; 32],
        decrypt_only: &[&[u8; 32]],
    ) -> Result<Self, CredentialError> {
        if decrypt_only.len() > 7 {
            return Err(CredentialError);
        }
        Self::from_keys(
            Key::from_material(Zeroizing::new(*active)),
            decrypt_only
                .iter()
                .map(|key| Ok(Key::from_material(Zeroizing::new(**key)))),
        )
    }

    fn from_keys(
        active: Key,
        old: impl ExactSizeIterator<Item = Result<Key, CredentialError>>,
    ) -> Result<Self, CredentialError> {
        let mut decrypt_only: Vec<Key> = Vec::with_capacity(old.len());
        for key in old {
            let key = key?;
            if key.id == active.id || decrypt_only.iter().any(|old| old.id == key.id) {
                return Err(CredentialError);
            }
            decrypt_only.push(key);
        }
        Ok(Self {
            active,
            decrypt_only,
        })
    }

    /// Load Swift's standalone hex key or format 1 keyring from a private file.
    pub fn load(
        path: &Path,
        admin_path: Option<&Path>,
        forbidden_digest: Option<&str>,
    ) -> Result<Self, CredentialError> {
        let data = private_data(path, 8192).map_err(|_| CredentialError)?;
        let text = secret_text(&data)?;
        let admin = admin_path
            .map(|path| private_data(path, 16_384).map_err(|_| CredentialError))
            .transpose()?;
        let admin = admin
            .as_ref()
            .map(|data| {
                let value = secret_text(data)?;
                if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_graphic()) {
                    return Err(CredentialError);
                }
                Ok(value)
            })
            .transpose()?;
        let check = |value: &str| {
            let lowercase = Zeroizing::new(value.to_lowercase());
            let uppercase = Zeroizing::new(value.to_uppercase());
            if admin.is_some_and(|secret| secret.eq_ignore_ascii_case(&lowercase))
                || forbidden_digest.is_some_and(|digest| {
                    [value, &lowercase, &uppercase]
                        .into_iter()
                        .any(|value| key_digest(value) == digest)
                })
            {
                return Err(CredentialError);
            }
            Ok(())
        };
        check(text)?;
        if !text.starts_with('{') {
            return Self::from_hex(text, &[]);
        }
        let ring: Keyring = serde_json::from_slice(&data).map_err(|_| CredentialError)?;
        if ring.format != 1.0 || ring.decrypt_only.len() > 7 {
            return Err(CredentialError);
        }
        check(&ring.active)?;
        let old: Vec<_> = ring.decrypt_only.iter().map(String::as_str).collect();
        for key in &old {
            check(key)?;
        }
        Self::from_hex(&ring.active, &old)
    }

    pub fn key_id(&self) -> &str {
        &self.active.id
    }

    pub fn available_key_ids(&self) -> Vec<&str> {
        let mut ids: Vec<_> = std::iter::once(&self.active)
            .chain(&self.decrypt_only)
            .map(|key| key.id.as_str())
            .collect();
        ids.sort_unstable();
        ids
    }

    pub fn seal(
        &self,
        credential: &AccountCredential,
        context: &AccountCredentialContext<'_>,
    ) -> Result<String, CredentialError> {
        let key = &self.active;
        let mut plaintext =
            Zeroizing::new(serde_json::to_vec(&credential.0).map_err(|_| CredentialError)?);
        if plaintext.len() > MAX_PLAINTEXT {
            return Err(CredentialError);
        }
        let mut nonce = [0; NONCE_BYTES];
        OsRng
            .try_fill_bytes(&mut nonce)
            .map_err(|_| CredentialError)?;
        let tag = key
            .cipher()
            .encrypt_in_place_detached(
                Nonce::from_slice(&nonce),
                context.aad(&key.id)?.as_bytes(),
                &mut plaintext,
            )
            .map_err(|_| CredentialError)?;
        let mut combined = Vec::with_capacity(NONCE_BYTES + plaintext.len() + TAG_BYTES);
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&plaintext);
        combined.extend_from_slice(&tag);
        let envelope = format!("v1.{}.{}", key.id, STANDARD.encode(combined));
        if envelope.len() > MAX_ENVELOPE {
            return Err(CredentialError);
        }
        Ok(envelope)
    }

    pub fn open(
        &self,
        envelope: &str,
        context: &AccountCredentialContext<'_>,
    ) -> Result<AccountCredential, CredentialError> {
        let (id, encoded) = envelope_parts(envelope)?;
        let key = std::iter::once(&self.active)
            .chain(&self.decrypt_only)
            .find(|key| key.id == id)
            .ok_or(CredentialError)?;
        let combined = STANDARD.decode(encoded).map_err(|_| CredentialError)?;
        if !(NONCE_BYTES + TAG_BYTES..=NONCE_BYTES + MAX_PLAINTEXT + TAG_BYTES)
            .contains(&combined.len())
            || STANDARD.encode(&combined) != encoded
        {
            return Err(CredentialError);
        }
        let (nonce, body) = combined.split_at(NONCE_BYTES);
        let (body, tag) = body.split_at(body.len() - TAG_BYTES);
        let mut plaintext = Zeroizing::new(body.to_vec());
        key.cipher()
            .decrypt_in_place_detached(
                Nonce::from_slice(nonce),
                context.aad(id)?.as_bytes(),
                &mut plaintext,
                Tag::from_slice(tag),
            )
            .map_err(|_| CredentialError)?;
        AccountCredential::from_payload(
            serde_json::from_slice(&plaintext).map_err(|_| CredentialError)?,
        )
    }

    /// Identify the required key for a backup inventory, prior to authenticating the envelope.
    pub fn envelope_key_id(envelope: &str) -> Result<&str, CredentialError> {
        Ok(envelope_parts(envelope)?.0)
    }
}

fn envelope_parts(envelope: &str) -> Result<(&str, &str), CredentialError> {
    if envelope.len() > MAX_ENVELOPE {
        return Err(CredentialError);
    }
    let mut parts = envelope.split('.');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some("v1"), Some(id), Some(encoded), None) if valid_key_id(id) => Ok((id, encoded)),
        _ => Err(CredentialError),
    }
}

fn secret_text(data: &[u8]) -> Result<&str, CredentialError> {
    // Foundation's whitespacesAndNewlines also trims the zero width space.
    Ok(std::str::from_utf8(data)
        .map_err(|_| CredentialError)?
        .trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}'))
}

pub(crate) fn valid_key_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}
