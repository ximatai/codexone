//! Strict management request shapes. Route authentication and request limits belong to the caller.
use codexone_governance::{Error, Result};
use serde::Deserialize;

use crate::{PrimingSettings, ResetSettings, reset_types::valid_credit};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrimingSettingsUpdate {
    pub revision: i64,
    pub enabled: bool,
    // The field must be present, with null selecting the current default model.
    #[serde(deserialize_with = "Deserialize::deserialize")]
    pub model: Option<String>,
    pub message: String,
}

impl PrimingSettingsUpdate {
    pub fn settings(self) -> (i64, PrimingSettings) {
        (
            self.revision,
            PrimingSettings {
                enabled: self.enabled,
                model: self.model,
                message: self.message,
            },
        )
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum ResetSettingsUpdate {
    Minutes(ResetMinutes),
    Hours(ResetHours),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResetMinutes {
    revision: i64,
    auto_use_before_expiry: bool,
    lead_minutes: u16,
    retry_count: u8,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResetHours {
    revision: i64,
    auto_use_before_expiry: bool,
    lead_hours: u16,
}

impl ResetSettingsUpdate {
    pub fn settings(self) -> Result<(i64, ResetSettings)> {
        let (revision, settings) = match self {
            Self::Minutes(update) => (
                update.revision,
                ResetSettings {
                    auto_use_before_expiry: update.auto_use_before_expiry,
                    lead_minutes: update.lead_minutes,
                    retry_count: update.retry_count,
                },
            ),
            Self::Hours(update) if (1..=24).contains(&update.lead_hours) => (
                update.revision,
                ResetSettings {
                    auto_use_before_expiry: update.auto_use_before_expiry,
                    lead_minutes: update.lead_hours * 60,
                    ..ResetSettings::default()
                },
            ),
            Self::Hours(_) => return Err(Error::InvalidCommand),
        };
        if !settings.validate() {
            return Err(Error::InvalidCommand);
        }
        Ok((revision, settings))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResetConsume {
    #[serde(rename = "creditID", default, deserialize_with = "credit_id")]
    pub credit_id: Option<String>,
}

fn credit_id<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<String>, D::Error> {
    let id = String::deserialize(deserializer)?;
    if !valid_credit(&id, 256) {
        return Err(serde::de::Error::custom("invalid credit ID"));
    }
    Ok(Some(id))
}
