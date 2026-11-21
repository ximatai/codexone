use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    claims::{MAX_EPOCH, integer, visible},
    provider::present,
};

const MAX_WINDOW_SECONDS: i64 = 31_536_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaFailure {
    Unavailable,
    AuthorizationRejected,
    RateLimited,
    InvalidResponse,
    RefreshRequired,
    Capacity,
    Closed,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub reset_after_seconds: Option<i64>,
    pub used_percent: Option<f64>,
    pub duration_seconds: Option<i64>,
    pub resets_at_unix_seconds: Option<i64>,
}

impl QuotaWindow {
    fn parse(doc: &Value) -> Result<Self, QuotaFailure> {
        if !doc.is_object() {
            return Err(QuotaFailure::InvalidResponse);
        }
        Ok(Self {
            reset_after_seconds: optional(doc, "reset_after_seconds", integer, |n| {
                (0..=MAX_WINDOW_SECONDS).contains(n)
            })?,
            used_percent: optional(doc, "used_percent", Value::as_f64, |n| {
                (0.0..=10_000.0).contains(n)
            })?,
            duration_seconds: optional(doc, "limit_window_seconds", integer, |n| {
                (1..=MAX_WINDOW_SECONDS).contains(n)
            })?,
            resets_at_unix_seconds: optional(doc, "reset_at", integer, |n| {
                (1..=MAX_EPOCH).contains(n)
            })?,
        })
    }

    fn validate(&self) -> bool {
        self.reset_after_seconds
            .is_none_or(|n| (0..=MAX_WINDOW_SECONDS).contains(&n))
            && self
                .used_percent
                .is_none_or(|n| (0.0..=10_000.0).contains(&n))
            && self
                .duration_seconds
                .is_none_or(|n| (1..=MAX_WINDOW_SECONDS).contains(&n))
            && self
                .resets_at_unix_seconds
                .is_none_or(|n| (1..=MAX_EPOCH).contains(&n))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuotaLimit {
    pub id: String,
    pub allowed: Option<bool>,
    pub limit_reached: Option<bool>,
    pub primary: Option<QuotaWindow>,
    pub secondary: Option<QuotaWindow>,
}

impl QuotaLimit {
    fn parse(doc: &Value, id: &str) -> Result<Self, QuotaFailure> {
        if !doc.is_object() || !visible(id, 128) {
            return Err(QuotaFailure::InvalidResponse);
        }
        Ok(Self {
            id: id.into(),
            allowed: optional(doc, "allowed", Value::as_bool, |_| true)?,
            limit_reached: optional(doc, "limit_reached", Value::as_bool, |_| true)?,
            primary: present(doc, "primary_window")
                .map(QuotaWindow::parse)
                .transpose()?,
            secondary: present(doc, "secondary_window")
                .map(QuotaWindow::parse)
                .transpose()?,
        })
    }
}

// Swift's synthesized enum encoding uses {"balance":{"_0":"..."}} and {"unlimited":{}}.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum UsageCredits {
    Balance { _0: String },
    Unlimited {},
}

pub(crate) fn valid_balance(text: &str) -> bool {
    let digits =
        |text: &str| (1..=18).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_digit());
    let (whole, fraction) = text
        .split_once('.')
        .map_or((text, None), |(a, b)| (a, Some(b)));
    digits(whole) && fraction.is_none_or(digits)
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionQuota {
    pub limits: Vec<QuotaLimit>,
    pub available_reset_credits: Option<i64>,
    pub usage_credits: Option<UsageCredits>,
}

impl SubscriptionQuota {
    pub(crate) fn parse(doc: &Value) -> Result<Self, QuotaFailure> {
        let mut limits = Vec::new();
        if let Some(base) = present(doc, "rate_limit") {
            limits.push(QuotaLimit::parse(base, "codex")?);
        }
        if let Some(additional) = present(doc, "additional_rate_limits") {
            let entries = additional
                .as_array()
                .filter(|entries| entries.len() <= 16)
                .ok_or(QuotaFailure::InvalidResponse)?;
            for entry in entries {
                let id = entry["metered_feature"]
                    .as_str()
                    .or_else(|| entry["limit_name"].as_str())
                    .ok_or(QuotaFailure::InvalidResponse)?;
                if let Some(limit) = present(entry, "rate_limit") {
                    limits.push(QuotaLimit::parse(limit, id)?);
                }
            }
        }
        let available_reset_credits = present(doc, "rate_limit_reset_credits")
            .map(|value| integer(&value["available_count"]).ok_or(QuotaFailure::InvalidResponse))
            .transpose()?;
        let credits = &doc["credits"];
        let usage_credits = match credits.get("unlimited") {
            Some(Value::Bool(true)) => Some(UsageCredits::Unlimited {}),
            Some(Value::Bool(false)) | None => credits["balance"]
                .as_str()
                .filter(|text| valid_balance(text))
                .map(|text| UsageCredits::Balance { _0: text.into() }),
            _ => None,
        };
        let quota = Self {
            limits,
            available_reset_credits,
            usage_credits,
        };
        quota
            .validate()
            .then_some(quota)
            .ok_or(QuotaFailure::InvalidResponse)
    }

    pub(crate) fn validate(&self) -> bool {
        if self.limits.len() > 17
            || self
                .limits
                .iter()
                .filter(|limit| limit.id != "codex")
                .count()
                > 16
            || !self
                .available_reset_credits
                .is_none_or(|n| (0..=128).contains(&n))
            || matches!(&self.usage_credits, Some(UsageCredits::Balance { _0 }) if !valid_balance(_0))
        {
            return false;
        }
        let mut ids = HashSet::new();
        self.limits.iter().all(|limit| {
            visible(&limit.id, 128)
                && ids.insert(&limit.id)
                && limit.primary.as_ref().is_none_or(QuotaWindow::validate)
                && limit.secondary.as_ref().is_none_or(QuotaWindow::validate)
        })
    }
}

fn optional<T>(
    doc: &Value,
    key: &str,
    parse: impl FnOnce(&Value) -> Option<T>,
    valid: impl FnOnce(&T) -> bool,
) -> Result<Option<T>, QuotaFailure> {
    present(doc, key)
        .map(|value| {
            parse(value)
                .filter(valid)
                .ok_or(QuotaFailure::InvalidResponse)
        })
        .transpose()
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub attempted_at_unix_seconds: Option<i64>,
    pub observed_at_unix_seconds: Option<i64>,
    pub quota: Option<SubscriptionQuota>,
    pub failure: Option<QuotaFailure>,
    pub(crate) trend: Option<QuotaTrend>,
}

impl Observation {
    pub fn is_fresh(&self, now: i64) -> bool {
        self.observed_at_unix_seconds.is_some_and(|at| {
            now.checked_sub(at)
                .is_some_and(|age| (0..300).contains(&age))
        })
    }

    pub(crate) fn validate(&self) -> bool {
        self.attempted_at_unix_seconds
            .is_none_or(|at| (1..=MAX_EPOCH).contains(&at))
            && self
                .observed_at_unix_seconds
                .is_none_or(|at| (1..=MAX_EPOCH).contains(&at))
            && self.observed_at_unix_seconds.is_some() == self.quota.is_some()
            && (self.failure.is_none() || self.attempted_at_unix_seconds.is_some())
            && self.quota.as_ref().is_none_or(SubscriptionQuota::validate)
            && self.trend.as_ref().is_none_or(QuotaTrend::validate)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub(crate) struct QuotaTrend {
    pub primary: Option<WindowTrend>,
    pub secondary: Option<WindowTrend>,
}

impl QuotaTrend {
    fn validate(&self) -> bool {
        self.primary.as_ref().is_none_or(WindowTrend::validate)
            && self.secondary.as_ref().is_none_or(WindowTrend::validate)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub(crate) struct WindowTrend {
    pub reset: i64,
    pub duration: i64,
    pub samples: Vec<(i64, f64)>,
}

impl WindowTrend {
    pub fn recording(
        window: Option<&QuotaWindow>,
        at: i64,
        previous: Option<&Self>,
    ) -> Option<Self> {
        let window = window?;
        let sample = (at, (100.0 - window.used_percent?).max(0.0));
        let reset = window.resets_at_unix_seconds?;
        let duration = window.duration_seconds?;
        if reset <= at || at < reset - duration - 60 {
            return None;
        }
        let mut current = previous
            .filter(|previous| previous.continues(reset, duration, sample))
            .cloned()
            .unwrap_or_else(|| Self {
                reset,
                duration,
                samples: Vec::new(),
            });
        current.samples.retain(|(time, _)| *time >= at - 86_400);
        if current
            .samples
            .last()
            .is_some_and(|last| last.0 / 300 == at / 300)
        {
            current.samples.pop();
        }
        current.samples.push(sample);
        Some(current)
    }

    pub fn continues(&self, reset: i64, duration: i64, sample: (i64, f64)) -> bool {
        self.reset > sample.0
            && (self.reset - reset).abs() <= 60
            && self.duration == duration
            && self
                .samples
                .last()
                .is_some_and(|last| last.0 <= sample.0 && last.1 >= sample.1)
    }

    fn validate(&self) -> bool {
        (1..=MAX_EPOCH).contains(&self.reset)
            && (1..=MAX_WINDOW_SECONDS).contains(&self.duration)
            && self.samples.iter().all(|(at, remaining)| {
                (1..=MAX_EPOCH).contains(at) && (0.0..=100.0).contains(remaining)
            })
    }
}
