use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub(crate) const CLIENT: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub(crate) const ISSUER: &str = "https://auth.openai.com";
pub(crate) const DATA_ORIGIN: &str = "https://chatgpt.com/backend-api/codex";
pub(crate) const MAX_EPOCH: i64 = 1_000_000_000_000;

pub(crate) struct Claims {
    subject: String,
    pub account: String,
    user: Option<String>,
    pub expires: i64,
}

impl Claims {
    pub fn id(token: &str, nonce: Option<&str>, now: Option<i64>) -> Option<Self> {
        let doc = jwt(token)?;
        let audience = match doc.get("aud")? {
            Value::String(value) => value == CLIENT,
            Value::Array(values) if values.len() <= 16 => {
                values.iter().all(Value::is_string)
                    && values.iter().any(|value| value.as_str() == Some(CLIENT))
                    && (values.len() == 1 || doc["azp"].as_str() == Some(CLIENT))
            }
            _ => false,
        };
        if !audience
            || doc
                .get("azp")
                .is_some_and(|value| value.as_str() != Some(CLIENT))
            || nonce.is_some_and(|value| doc["nonce"].as_str() != Some(value))
        {
            return None;
        }
        Self::parse(&doc, now)
    }

    pub fn access(token: &str, now: i64) -> Option<Self> {
        Self::parse(&jwt(token)?, Some(now))
    }

    fn parse(value: &Value, now: Option<i64>) -> Option<Self> {
        if !matches!(
            value["iss"].as_str(),
            Some(ISSUER | "https://auth.openai.com/")
        ) {
            return None;
        }
        let subject = value["sub"].as_str().filter(|text| visible(text, 256))?;
        let auth = &value["https://api.openai.com/auth"];
        let account = auth["chatgpt_account_id"]
            .as_str()
            .filter(|text| visible(text, 128))?;
        let user = match auth.get("chatgpt_user_id").or_else(|| auth.get("user_id")) {
            Some(user) => Some(user.as_str().filter(|text| visible(text, 128))?.into()),
            None => None,
        };
        let expires = integer(&value["exp"]).filter(|time| (1..=MAX_EPOCH).contains(time))?;
        if let Some(now) = now {
            if expires <= now {
                return None;
            }
            for field in ["iat", "nbf"] {
                if let Some(time) = value.get(field) {
                    integer(time).filter(|time| (0..=now + 60).contains(time))?;
                }
            }
        }
        Some(Self {
            subject: subject.into(),
            account: account.into(),
            user,
            expires,
        })
    }

    pub fn matches(&self, other: &Self) -> bool {
        self.subject == other.subject
            && self.account == other.account
            && self
                .user
                .as_ref()
                .zip(other.user.as_ref())
                .is_none_or(|(a, b)| a == b)
    }

    pub fn namespace(&self, realm: &str) -> String {
        let scope = [
            DATA_ORIGIN,
            "codex-subscription",
            realm,
            CLIENT,
            &self.subject,
            &self.account,
        ];
        // Foundation JSONEncoder's default also escapes forward slashes.
        let encoded = serde_json::to_string(&scope)
            .expect("string array")
            .replace('/', "\\/");
        format!("subscription-{:x}", Sha256::digest(encoded))
    }
}

pub(crate) fn visible(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.len() <= maximum && value.bytes().all(|b| (33..=126).contains(&b))
}

pub(crate) fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let number = value.as_number()?;
        codexone_wire::JsonValue::decode(number.as_str().as_bytes())
            .ok()?
            .as_i64()
    })
}

fn jwt(token: &str) -> Option<Value> {
    if token.len() > 16_384 {
        return None;
    }
    let mut parts = token.split('.');
    let header = decode(parts.next()?)?;
    let payload = decode(parts.next()?)?;
    decode(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    let header: Value = serde_json::from_slice(&header).ok()?;
    if !matches!(header["alg"].as_str(), Some("RS256" | "ES256")) {
        return None;
    }
    let claims: Value = serde_json::from_slice(&payload).ok()?;
    claims.is_object().then_some(claims)
}

fn decode(part: &str) -> Option<Zeroizing<Vec<u8>>> {
    if part.is_empty() {
        return None;
    }
    // URL_SAFE_NO_PAD requires the unpadded alphabet and canonical trailing bits.
    URL_SAFE_NO_PAD.decode(part).ok().map(Zeroizing::new)
}
