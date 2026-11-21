use std::collections::HashSet;

use codexone_governance::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use unicode_general_category::{GeneralCategory, get_general_category};
use uuid::Uuid;

pub(crate) fn valid_credit(id: &str, max: usize) -> bool {
    (1..=max).contains(&id.len()) && id.bytes().all(|c| (33..=126).contains(&c))
}

pub(crate) fn expiry(raw: &str) -> Option<f64> {
    if raw.len() > 64 {
        return None;
    }
    let timestamp = OffsetDateTime::parse(raw, &Rfc3339)
        .ok()?
        .unix_timestamp_nanos();
    (timestamp > 0).then_some(timestamp as f64 / 1_000_000_000.)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct ResetCredit {
    pub id: String,
    #[serde(rename(serialize = "type", deserialize = "reset_type"))]
    pub kind: String,
    pub status: String,
    pub granted_at: String,
    pub expires_at: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
}

impl ResetCredit {
    fn is_valid(&self) -> bool {
        let text = |value: Option<&str>, max| {
            value.is_none_or(|s| {
                s.len() <= max
                    && !s.chars().any(|ch| {
                        ch.is_control() || get_general_category(ch) == GeneralCategory::Format
                    })
            })
        };
        valid_credit(&self.id, 256)
            && valid_credit(&self.kind, 64)
            && valid_credit(&self.status, 64)
            && expiry(&self.granted_at).is_some()
            && self
                .expires_at
                .as_deref()
                .is_none_or(|value| expiry(value).is_some())
            && text(self.title.as_deref(), 512)
            && text(self.description.as_deref(), 2048)
    }

    pub(crate) fn expires(&self) -> Option<f64> {
        self.expires_at.as_deref().and_then(expiry)
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct ResetList {
    pub credits: Vec<ResetCredit>,
    pub available_count: u8,
}

#[derive(Debug, Serialize)]
pub struct ResetListing {
    #[serde(flatten)]
    pub list: ResetList,
    pub state: ResetStatus,
}

impl ResetList {
    pub(crate) fn parse(value: Value) -> Result<Self> {
        let list: Self =
            serde_json::from_value(value).map_err(|_| Error::AuthorizationUnavailable)?;
        let mut ids = HashSet::new();
        if list.credits.len() > 128
            || list.available_count > 128
            || !list
                .credits
                .iter()
                .all(|credit| credit.is_valid() && ids.insert(&credit.id))
        {
            return Err(Error::AuthorizationUnavailable);
        }
        Ok(list)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResetCode {
    Reset,
    NothingToReset,
    NoCredit,
    AlreadyRedeemed,
    Unknown,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetResult {
    pub code: ResetCode,
    pub windows_reset: u8,
}

impl ResetResult {
    pub(crate) const UNKNOWN: Self = Self {
        code: ResetCode::Unknown,
        windows_reset: 0,
    };

    pub(crate) fn parse(value: Value) -> Self {
        let Ok(code) = serde_json::from_value::<ResetCode>(value["code"].clone()) else {
            return Self::UNKNOWN;
        };
        if code == ResetCode::Unknown {
            return Self::UNKNOWN;
        }
        value["windows_reset"]
            .as_u64()
            .filter(|count| *count <= 128)
            .map_or(Self::UNKNOWN, |count| Self {
                code,
                windows_reset: count as u8,
            })
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ResetSettings {
    pub auto_use_before_expiry: bool,
    pub lead_minutes: u16,
    pub retry_count: u8,
}

impl Default for ResetSettings {
    fn default() -> Self {
        Self {
            auto_use_before_expiry: false,
            lead_minutes: 1440,
            retry_count: 3,
        }
    }
}

impl ResetSettings {
    pub(crate) fn validate(self) -> bool {
        (1..=1440).contains(&self.lead_minutes)
            && self.retry_count <= 5
            && self.lead_minutes > u16::from(self.retry_count)
    }
}

impl Serialize for ResetSettings {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut out = serializer.serialize_struct("ResetSettings", 4)?;
        out.serialize_field("autoUseBeforeExpiry", &self.auto_use_before_expiry)?;
        out.serialize_field("leadMinutes", &self.lead_minutes)?;
        out.serialize_field("retryCount", &self.retry_count)?;
        out.serialize_field("leadHours", &self.lead_minutes.div_ceil(60))?;
        out.end()
    }
}

impl<'de> Deserialize<'de> for ResetSettings {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Stored {
            auto_use_before_expiry: bool,
            lead_minutes: Option<u16>,
            retry_count: Option<u8>,
            lead_hours: Option<u16>,
        }
        let stored = Stored::deserialize(deserializer)?;
        let lead_minutes = stored
            .lead_minutes
            .or_else(|| {
                stored
                    .lead_hours
                    .filter(|hours| (1..=168).contains(hours))
                    .map(|hours| (hours * 60).min(1440))
            })
            .ok_or_else(|| serde::de::Error::custom("invalid reset lead"))?;
        let settings = Self {
            auto_use_before_expiry: stored.auto_use_before_expiry,
            lead_minutes,
            retry_count: stored.retry_count.unwrap_or(3),
        };
        settings
            .validate()
            .then_some(settings)
            .ok_or_else(|| serde::de::Error::custom("invalid reset settings"))
    }
}

/// Safe management view. The provider's idempotency identifier is internal.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetStatus {
    pub revision: i64,
    pub settings: ResetSettings,
    pub pending: bool,
    #[serde(rename = "pendingCreditID")]
    pub pending_credit_id: Option<String>,
    pub last_code: Option<ResetCode>,
    pub last_attempt_at: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub(crate) struct Intent {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "creditID")]
    pub credit_id: Option<String>,
    pub automatic: bool,
}

impl Intent {
    pub fn valid(&self) -> bool {
        Uuid::parse_str(&self.request_id).is_ok()
            && self
                .credit_id
                .as_deref()
                .is_none_or(|id| valid_credit(id, 256))
    }
}
