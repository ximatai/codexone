//! Quota window evidence stored in the Swift v19 format.
use std::collections::BTreeMap;

use codexone_governance::{Error, Result};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use unicode_general_category::{GeneralCategory::*, get_general_category};

use crate::{Observation, claims::MAX_EPOCH, store};

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct PrimingSettings {
    pub enabled: bool,
    pub model: Option<String>,
    pub message: String,
}

impl Default for PrimingSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            model: None,
            message: "hello".into(),
        }
    }
}

impl PrimingSettings {
    pub fn validate(&self) -> Result<()> {
        if self
            .model
            .as_ref()
            .is_some_and(|m| m.is_empty() || m.len() > 128)
            || !(1..=200).contains(&self.message.chars().count())
            || self.message.chars().any(|ch| {
                matches!(
                    get_general_category(ch),
                    Control | Format | LineSeparator | ParagraphSeparator
                ) || (matches!(get_general_category(ch), Unassigned)
                    && matches!(u32::from(ch) >> 16, 0..=3 | 14))
                    || (0xfdd0..=0xfdef).contains(&u32::from(ch))
                    || u32::from(ch) & 0xffff >= 0xfffe
            })
        {
            return Err(Error::InvalidCommand);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    FiveHour,
    Weekly,
}

impl Kind {
    fn duration(self) -> i64 {
        match self {
            Self::FiveHour => 18_000,
            Self::Weekly => 604_800,
        }
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    last_attempt_at: Option<i64>,
    observed_reset_at: Option<i64>,
    awaiting_active: bool,
    active_reset_at: Option<i64>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrimingState {
    pub revision: i64,
    pub settings: PrimingSettings,
    windows: BTreeMap<Kind, Window>,
    pub last_attempt_at: Option<i64>,
    pub last_result: Option<String>,
    pub failures: u32,
    pub attention: Option<String>,
}

impl Default for PrimingState {
    fn default() -> Self {
        Self {
            revision: 1,
            settings: PrimingSettings::default(),
            windows: BTreeMap::new(),
            last_attempt_at: None,
            last_result: None,
            failures: 0,
            attention: None,
        }
    }
}

enum Status {
    Idle(i64),
    Active(i64),
}

fn evidence(observation: &Observation, now: i64) -> impl Iterator<Item = (Kind, Status)> {
    let base = observation
        .quota
        .as_ref()
        .and_then(|quota| quota.limits.iter().find(|limit| limit.id == "codex"))
        .filter(|base| base.allowed != Some(false) && base.limit_reached != Some(true))
        .filter(|_| observation.failure.is_none() && observation.is_fresh(now));
    [Kind::FiveHour, Kind::Weekly]
        .into_iter()
        .filter_map(move |kind| {
            let base = base?;
            let at = observation.observed_at_unix_seconds?;
            let duration = kind.duration();
            let mut matching = [&base.primary, &base.secondary]
                .into_iter()
                .filter_map(Option::as_ref)
                .filter(|window| window.duration_seconds == Some(duration));
            let window = matching.next()?;
            if matching.next().is_some() {
                return None;
            }
            let used = window.used_percent?;
            let reset = window.resets_at_unix_seconds?;
            let remaining = reset - at;
            if !(1..=duration + 5).contains(&remaining)
                || window
                    .reset_after_seconds
                    .is_some_and(|after| (after - remaining).abs() > 5)
            {
                return None;
            }
            if used == 0.0
                && window.reset_after_seconds == Some(duration)
                && (remaining - duration).abs() <= 5
            {
                Some((kind, Status::Idle(reset)))
            } else if used > 0.0 || remaining < duration - 60 {
                Some((kind, Status::Active(reset)))
            } else {
                None
            }
        })
}

impl PrimingState {
    pub fn load(db: &Connection, id: &str) -> Result<Self> {
        let raw: Option<String> = db
            .query_row(
                "SELECT record_json FROM account_quota_priming WHERE account_id=?",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(raw) = raw else {
            return Ok(Self::default());
        };
        let state: Self = serde_json::from_str(&raw).map_err(|_| Error::Unavailable)?;
        state.settings.validate().map_err(|_| Error::Unavailable)?;
        if state.failures > 1_000_000
            || state.windows.values().any(|w| {
                [w.last_attempt_at, w.observed_reset_at, w.active_reset_at]
                    .into_iter()
                    .flatten()
                    .any(|t| !(1..=MAX_EPOCH).contains(&t))
                    || (w.awaiting_active && w.last_attempt_at.is_none())
            })
        {
            return Err(Error::Unavailable);
        }
        Ok(state)
    }

    pub fn save(&self, tx: &Transaction<'_>, id: &str) -> Result<()> {
        tx.execute(
            "INSERT INTO account_quota_priming VALUES(?,?) ON CONFLICT(account_id)
             DO UPDATE SET record_json=excluded.record_json",
            params![
                id,
                serde_json::to_string(self).map_err(|_| Error::Unavailable)?
            ],
        )?;
        Ok(())
    }

    fn eligible(&self, observation: &Observation, now: i64) -> Vec<(Kind, i64)> {
        if !self.settings.enabled
            || self.failures >= 3
            || self.windows.values().any(|w| w.awaiting_active)
        {
            return Vec::new();
        }
        let idle: Vec<_> = evidence(observation, now)
            .filter_map(|(kind, status)| match status {
                Status::Idle(reset) => Some((kind, reset)),
                Status::Active(_) => None,
            })
            .collect();
        if idle.iter().any(|(kind, _)| {
            self.windows.get(kind).is_some_and(|w| {
                w.last_attempt_at.is_some_and(|last| now - last < 3600)
                    || w.active_reset_at.is_some_and(|reset| now < reset)
            })
        }) {
            return Vec::new();
        }
        idle
    }

    pub fn ready(&self, observation: &Observation, now: i64) -> bool {
        !self.eligible(observation, now).is_empty()
    }

    /// Store the window barrier in the execution admission transaction.
    pub fn begin(&mut self, tx: &Transaction<'_>, id: &str, now: i64) -> Result<Vec<Kind>> {
        let observation = store::load_quota(tx, id)?;
        let idle = self.eligible(&observation, now);
        if idle.is_empty() {
            return Err(Error::AccountConflict);
        }
        for (kind, reset) in &idle {
            let window = self.windows.entry(*kind).or_default();
            window.last_attempt_at = Some(now);
            window.observed_reset_at = Some(*reset);
            window.awaiting_active = true;
        }
        self.last_attempt_at = Some(now);
        self.last_result = Some("pending".into());
        self.save(tx, id)?;
        Ok(idle.into_iter().map(|(kind, _)| kind).collect())
    }

    fn failed(&mut self, result: &str) -> bool {
        self.last_result = Some(result.into());
        self.failures = (self.failures + 1).min(1_000_000);
        if self.failures >= 3 && self.settings.enabled {
            self.settings.enabled = false;
            self.attention = Some("repeated_failure".into());
            return true;
        }
        false
    }

    pub fn finish(
        &mut self,
        tx: &Transaction<'_>,
        id: &str,
        result: &str,
        release: &[Kind],
    ) -> Result<()> {
        for kind in release {
            if let Some(window) = self.windows.get_mut(kind) {
                window.awaiting_active = false;
            }
        }
        if result == "success" {
            self.last_result = Some(result.into());
        } else if self.failed(result) {
            codexone_governance::bump_quota_revision(tx, id)?;
        }
        self.save(tx, id)
    }

    fn observe(&mut self, observation: &Observation, now: i64) -> bool {
        let Some(at) = observation.observed_at_unix_seconds else {
            return false;
        };
        let mut not_started = false;
        let mut changed = false;
        for (kind, status) in evidence(observation, now) {
            let Some(window) = self.windows.get_mut(&kind).filter(|w| w.awaiting_active) else {
                continue;
            };
            let Some(last) = window.last_attempt_at.filter(|last| *last < at) else {
                continue;
            };
            match status {
                Status::Active(reset) => {
                    window.active_reset_at = Some(reset);
                    window.awaiting_active = false;
                    self.failures = 0;
                    changed = true;
                }
                // Never clear an in-flight operation based on idle evidence.
                Status::Idle(_)
                    if at - last >= 900 && self.last_result.as_deref() != Some("pending") =>
                {
                    window.awaiting_active = false;
                    not_started = true;
                    changed = true;
                }
                _ => {}
            }
        }
        if not_started && self.last_result.as_deref() == Some("success") {
            self.failed("not_started");
        }
        changed
    }
}

pub(crate) fn record_observation(
    tx: &Transaction<'_>,
    id: &str,
    observation: &Observation,
    now: i64,
) -> Result<()> {
    let mut state = PrimingState::load(tx, id)?;
    let enabled = state.settings.enabled;
    if state.observe(observation, now) {
        if enabled && !state.settings.enabled {
            codexone_governance::bump_quota_revision(tx, id)?;
        }
        state.save(tx, id)?;
    }
    Ok(())
}
