use codexone_governance::Error as GovernanceError;
use codexone_identity_runtime::priming::{Kind, PrimingSettings, PrimingState};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::{Admission, ExecutionError as Error, Failure, Outcome, Result};

fn storage_or_conflict(error: GovernanceError) -> Error {
    match error {
        GovernanceError::AccountConflict => Error::Conflict,
        _ => Error::StorageUnavailable,
    }
}

pub(crate) fn begin(
    tx: &Transaction<'_>,
    admission: &Admission,
    settings: &PrimingSettings,
    now: i64,
) -> Result<()> {
    let id = &admission.owner.identity;
    let mut state = PrimingState::load(tx, id).map_err(storage_or_conflict)?;
    if &state.settings != settings {
        return Err(Error::Conflict);
    }
    let count: i64 = tx.query_row("SELECT COUNT(*) FROM quota_priming_events", [], |r| {
        r.get(0)
    })?;
    if count >= 4096 {
        return Err(Error::Capacity);
    }
    let kinds = state.begin(tx, id, now).map_err(storage_or_conflict)?;
    tx.execute(
        "INSERT INTO quota_priming_events VALUES(?,?,?,?,'pending',?)",
        params![
            admission.attempt,
            id,
            serde_json::to_string(&kinds)?,
            admission.model,
            now
        ],
    )?;
    Ok(())
}

pub(crate) fn recover(tx: &Transaction<'_>) -> Result<()> {
    let mut statement =
        tx.prepare("SELECT id FROM quota_priming_events WHERE result='pending' LIMIT 65")?;
    let ids = statement
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if ids.len() > 64 {
        return Err(Error::StorageUnavailable);
    }
    for id in ids {
        finish(tx, &id, None)?;
    }
    Ok(())
}

pub(crate) fn finish(tx: &Transaction<'_>, attempt: &str, outcome: Option<&Outcome>) -> Result<()> {
    let pending = tx.query_row("SELECT account_id,windows_json FROM quota_priming_events WHERE id=? AND result='pending'",
        [attempt], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))).optional()?;
    let Some((id, kinds)) = pending else {
        return Ok(());
    };
    let mut release = Vec::<Kind>::new();
    let encoded;
    let result = match outcome.map(|outcome| outcome.failure) {
        None => "unknown",
        Some(None) => "success",
        Some(Some(failure)) => {
            if !matches!(
                failure,
                Failure::InvalidUpstreamResponse
                    | Failure::DeadlineExceeded
                    | Failure::ClientCancelled
                    | Failure::Indeterminate
            ) {
                release = serde_json::from_str(&kinds)?;
            }
            encoded = serde_json::to_value(failure)?;
            encoded.as_str().ok_or(Error::StorageUnavailable)?
        }
    };
    let mut state = PrimingState::load(tx, &id).map_err(storage_or_conflict)?;
    state
        .finish(tx, &id, result, &release)
        .map_err(storage_or_conflict)?;
    tx.execute(
        "UPDATE quota_priming_events SET result=? WHERE id=?",
        params![result, attempt],
    )?;
    Ok(())
}
