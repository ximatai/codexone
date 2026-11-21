use codexone_governance::{Account, AccountMode, AuthorizationState, Error, Result, quota_account};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::reset_types::{Intent, ResetCode, ResetSettings, ResetStatus};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct State {
    pub revision: i64,
    pub settings: ResetSettings,
    pub intent: Option<Intent>,
    pub last_code: Option<ResetCode>,
    pub failures: u32,
    pub last_attempt_at: Option<i64>,
    pub last_auto_reset_at: Option<i64>,
    pub last_failure_at: Option<i64>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            revision: 1,
            settings: ResetSettings::default(),
            intent: None,
            last_code: None,
            failures: 0,
            last_attempt_at: None,
            last_auto_reset_at: None,
            last_failure_at: None,
        }
    }
}

impl State {
    pub fn load(db: &Connection, id: &str) -> Result<Self> {
        let raw: Option<String> = db
            .query_row(
                "SELECT record_json FROM account_reset_credits WHERE account_id=?",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(raw) = raw else {
            return Ok(Self::default());
        };
        let state: Self = serde_json::from_str(&raw).map_err(|_| Error::Unavailable)?;
        if state.failures > 1_000_000 || state.intent.as_ref().is_some_and(|intent| !intent.valid())
        {
            return Err(Error::Unavailable);
        }
        Ok(state)
    }

    pub fn save(&self, tx: &Transaction<'_>, id: &str) -> Result<()> {
        tx.execute(
            "INSERT INTO account_reset_credits VALUES(?,?) ON CONFLICT(account_id)
            DO UPDATE SET record_json=excluded.record_json",
            params![
                id,
                serde_json::to_string(self).map_err(|_| Error::Unavailable)?
            ],
        )?;
        Ok(())
    }

    pub fn status(self, revision: i64) -> ResetStatus {
        ResetStatus {
            revision,
            settings: self.settings,
            pending: self.intent.is_some(),
            pending_credit_id: self.intent.and_then(|intent| intent.credit_id),
            last_code: self.last_code,
            last_attempt_at: self.last_attempt_at,
        }
    }

    fn failed(&mut self, now: i64) {
        self.failures = (self.failures + 1).min(1_000_000);
        self.last_failure_at = Some(now);
    }
}

pub(crate) struct Attempt {
    pub intent: Intent,
    pub audit_id: String,
}

fn uuid() -> String {
    uuid::Uuid::new_v4().to_string().to_ascii_uppercase()
}

fn audit(
    tx: &Transaction<'_>,
    id: &str,
    action: &str,
    code: &str,
    automatic: bool,
    credit: Option<&str>,
    now: i64,
) -> Result<String> {
    let count: i64 = tx.query_row("SELECT COUNT(*) FROM reset_credit_events", [], |r| r.get(0))?;
    if count >= 4096 {
        return Err(Error::Capacity);
    }
    let audit_id = uuid();
    let digest = credit.map(|credit| format!("{:x}", Sha256::digest(credit.as_bytes())));
    tx.execute(
        "INSERT INTO reset_credit_events VALUES(?,?,?,?,?,?,?)",
        params![audit_id, id, action, code, automatic, digest, now],
    )?;
    Ok(audit_id)
}

pub(crate) fn begin(
    tx: &Transaction<'_>,
    captured: &Account,
    credit_id: Option<String>,
    automatic: bool,
    expires_at: Option<f64>,
    access_expires_at: i64,
    now: i64,
) -> Result<Attempt> {
    let id = &captured.id;
    let current = quota_account(tx, id)?;
    if current.revision != captured.revision
        || current.namespace != captured.namespace
        || current.credential_version != captured.credential_version
        || current.authorization != AuthorizationState::Ready
        || access_expires_at <= now
    {
        return Err(Error::AccountConflict);
    }
    let mut state = State::load(tx, id)?;
    if automatic
        && (current.mode != AccountMode::Enabled
            || !state.settings.auto_use_before_expiry
            || !expires_at.is_some_and(|expiry| expiry > now as f64)
            || state
                .intent
                .as_ref()
                .is_some_and(|intent| !intent.automatic)
            || state.failures > u32::from(state.settings.retry_count)
            || state
                .last_failure_at
                .is_some_and(|at| now.saturating_sub(at) < 60))
    {
        return Err(Error::AccountConflict);
    }
    let intent = match &state.intent {
        Some(previous) => {
            if credit_id.is_some() && credit_id != previous.credit_id {
                return Err(Error::AccountConflict);
            }
            previous.clone()
        }
        None => Intent {
            request_id: uuid(),
            credit_id,
            automatic,
        },
    };
    let audit_id = audit(
        tx,
        id,
        "consume",
        "unknown",
        automatic,
        intent.credit_id.as_deref(),
        now,
    )?;
    state.intent = Some(intent.clone());
    state.last_code = Some(ResetCode::Unknown);
    state.last_attempt_at = Some(now);
    // Assume failure until the reply is durably confirmed, including after process loss.
    state.failed(now);
    state.save(tx, id)?;
    Ok(Attempt { intent, audit_id })
}

pub(crate) fn finish(
    tx: &Transaction<'_>,
    id: &str,
    attempt: &Attempt,
    code: ResetCode,
    now: i64,
) -> Result<()> {
    let mut state = State::load(tx, id)?;
    if state.intent.as_ref() != Some(&attempt.intent) {
        return Err(Error::AccountConflict);
    }
    if code != ResetCode::Unknown {
        let wire = serde_json::to_value(code).map_err(|_| Error::Unavailable)?;
        let wire = wire.as_str().ok_or(Error::Unavailable)?;
        if tx.execute(
            "UPDATE reset_credit_events SET code=? WHERE id=? AND account_id=? AND code='unknown'",
            params![wire, attempt.audit_id, id],
        )? != 1
        {
            return Err(Error::AccountConflict);
        }
        state.last_code = Some(code);
        state.failures = 0;
        state.last_failure_at = None;
        state.intent = None;
        if attempt.intent.automatic && code == ResetCode::Reset {
            state.last_auto_reset_at = Some(now);
        }
    } else {
        state.last_failure_at = Some(now);
    }
    state.save(tx, id)
}

pub(crate) fn poll_failed(tx: &Transaction<'_>, id: &str, revision: i64, now: i64) -> Result<u32> {
    if quota_account(tx, id)?.revision != revision {
        return Err(Error::AccountConflict);
    }
    let mut state = State::load(tx, id)?;
    audit(tx, id, "list", "unavailable", true, None, now)?;
    state.failed(now);
    state.save(tx, id)?;
    Ok(state.failures)
}

pub(crate) fn clear_poll_failures(tx: &Transaction<'_>, id: &str, revision: i64) -> Result<()> {
    if quota_account(tx, id)?.revision != revision {
        return Err(Error::AccountConflict);
    }
    let mut state = State::load(tx, id)?;
    if state.intent.is_none() && state.failures != 0 {
        state.failures = 0;
        state.last_failure_at = None;
        state.save(tx, id)?;
    }
    Ok(())
}
