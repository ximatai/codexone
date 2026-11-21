use std::path::Path;

use codexone_storage::Database;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::{Error, MAX_EPOCH, Result, audit, audit_reference, files, is_uuid, now};

const DAY: i64 = 86400;

#[derive(Clone, Copy)]
pub(crate) struct BusinessDay(i64);

impl BusinessDay {
    pub(crate) fn new(minutes: i16) -> Result<Self> {
        if !(-720..=840).contains(&minutes) || minutes % 60 != 0 {
            return Err(Error::Invalid);
        }
        Ok(Self(i64::from(minutes) * 60))
    }

    pub(crate) fn end(self, epoch: i64) -> i64 {
        ((epoch + self.0).div_euclid(DAY) + 1) * DAY - self.0
    }

    pub(crate) fn restore_day_end(self, epoch: i64) -> Option<i64> {
        (self.0 != 0).then(|| self.end(epoch))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreBaseline {
    pub expected_revision: i64,
    #[serde(rename = "restoreID")]
    pub restore_id: String,
    pub audit_reference: String,
    pub missing_unresolved_requests: i64,
    pub missing_unresolved_micros: i64,
    pub freeze_until_unix_seconds: i64,
}

impl RestoreBaseline {
    fn validate(&self) -> Result<()> {
        if !(0..1_000_000).contains(&self.expected_revision)
            || !is_uuid(&self.restore_id)
            || !audit_reference(&self.audit_reference)
            || !(0..=1_000_000).contains(&self.missing_unresolved_requests)
            || !(0..=MAX_EPOCH).contains(&self.missing_unresolved_micros)
            || (self.missing_unresolved_requests == 0 && self.missing_unresolved_micros != 0)
            || !(1..=MAX_EPOCH).contains(&self.freeze_until_unix_seconds)
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreRecord {
    pub id: String,
    #[serde(rename = "backupID")]
    pub backup_id: String,
    pub snapshot_unix_seconds: i64,
    pub restored_unix_seconds: i64,
    pub inherited_unresolved_requests: i64,
    pub inherited_unresolved_micros: i64,
    pub inherited_freeze_until_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub day_freeze_until_unix_seconds: Option<i64>,
    pub baseline_revision: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline: Option<RestoreBaseline>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reconciled_unix_seconds: Option<i64>,
}

impl RestoreRecord {
    pub(crate) fn minimum_freeze(&self) -> i64 {
        self.inherited_freeze_until_unix_seconds.max(
            self.day_freeze_until_unix_seconds
                .unwrap_or_else(|| BusinessDay(0).end(self.restored_unix_seconds)),
        )
    }

    fn minimum_reconciliation_freeze(&self, now: i64, day: BusinessDay) -> i64 {
        self.minimum_freeze()
            .max(self.baseline.as_ref().map_or_else(
                || day.end(now),
                |baseline| baseline.freeze_until_unix_seconds,
            ))
    }

    pub(crate) fn unresolved_requests(&self) -> i64 {
        self.baseline
            .as_ref()
            .map_or(self.inherited_unresolved_requests, |b| {
                b.missing_unresolved_requests
            })
    }

    pub(crate) fn unresolved_micros(&self) -> i64 {
        self.baseline
            .as_ref()
            .map_or(self.inherited_unresolved_micros, |b| {
                b.missing_unresolved_micros
            })
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if !is_uuid(&self.id)
            || !is_uuid(&self.backup_id)
            || !(1..=self.restored_unix_seconds).contains(&self.snapshot_unix_seconds)
            || self.restored_unix_seconds > MAX_EPOCH
            || !(0..=1_000_000).contains(&self.baseline_revision)
            || !(0..=1_000_000).contains(&self.inherited_unresolved_requests)
            || !(0..=MAX_EPOCH).contains(&self.inherited_unresolved_micros)
            || !(0..=MAX_EPOCH).contains(&self.inherited_freeze_until_unix_seconds)
            || self.day_freeze_until_unix_seconds.is_some_and(|end| {
                !(self.restored_unix_seconds + 1..=self.restored_unix_seconds + DAY).contains(&end)
            })
        {
            return Err(Error::Invalid);
        }

        if let Some(baseline) = &self.baseline {
            baseline.validate()?;
            if baseline.restore_id != self.id
                || baseline.freeze_until_unix_seconds < self.minimum_freeze()
                || self.baseline_revision != baseline.expected_revision + 1
                || !self
                    .reconciled_unix_seconds
                    .is_some_and(|at| (self.restored_unix_seconds..=MAX_EPOCH).contains(&at))
            {
                return Err(Error::Invalid);
            }
        } else if self.baseline_revision != 0 || self.reconciled_unix_seconds.is_some() {
            return Err(Error::Invalid);
        }
        Ok(())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreStatus {
    pub state: &'static str,
    pub restore: Option<RestoreRecord>,
    pub minimum_freeze_until_unix_seconds: Option<i64>,
    pub missing_unresolved_requests: i64,
    pub missing_unresolved_micros: i64,
}

impl RestoreStatus {
    pub(crate) fn new(restore: Option<RestoreRecord>, day: BusinessDay) -> Result<Self> {
        let now = now()?;
        let state = match &restore {
            None => "normal",
            Some(record) => match &record.baseline {
                None => "restored_unreconciled",
                Some(baseline) if now >= baseline.freeze_until_unix_seconds => "reconciled",
                Some(_) => "frozen",
            },
        };
        Ok(Self {
            state,
            minimum_freeze_until_unix_seconds: restore
                .as_ref()
                .map(|r| r.minimum_reconciliation_freeze(now, day)),
            missing_unresolved_requests: restore
                .as_ref()
                .map_or(0, RestoreRecord::unresolved_requests),
            missing_unresolved_micros: restore.as_ref().map_or(0, RestoreRecord::unresolved_micros),
            restore,
        })
    }
}

pub(crate) fn read_record(db: &Connection) -> Result<Option<RestoreRecord>> {
    let (present, record): (bool, Option<String>) = db.query_row(
        "SELECT restore_json IS NOT NULL,
          CASE WHEN length(CAST(restore_json AS BLOB))<=16384 THEN restore_json END
         FROM maintenance_state WHERE id=1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if !present {
        return Ok(None);
    }
    let record: RestoreRecord = serde_json::from_str(&record.ok_or(Error::Capacity)?)?;
    record.validate()?;
    Ok(Some(record))
}

pub(crate) fn status(path: &Path) -> Result<Option<RestoreRecord>> {
    read_record(Database::open_for_credential_maintenance(path)?.connection())
}

pub(crate) fn reconcile(path: &Path, baseline: &Path, day: BusinessDay) -> Result<RestoreRecord> {
    let proposed: RestoreBaseline = serde_json::from_slice(&files::read_bounded(baseline, 8192)?)?;
    proposed.validate()?;
    let mut db = Database::open_for_credential_maintenance(path)?;
    let tx = db.begin_immediate()?;
    let mut record = read_record(&tx)?.ok_or(Error::Conflict)?;
    if proposed.restore_id != record.id {
        return Err(Error::Conflict);
    }
    if record.baseline.as_ref() == Some(&proposed) {
        return Ok(record);
    }
    let at = now()?;
    if at < record.restored_unix_seconds {
        return Err(Error::Invalid);
    }
    if proposed.expected_revision != record.baseline_revision
        || proposed.freeze_until_unix_seconds < record.minimum_reconciliation_freeze(at, day)
        || (record.baseline_revision == 0
            && (proposed.missing_unresolved_requests < record.inherited_unresolved_requests
                || proposed.missing_unresolved_micros < record.inherited_unresolved_micros))
    {
        return Err(Error::Conflict);
    }
    crate::require_complete_reencryption(&tx)?;
    record.baseline = Some(proposed);
    record.baseline_revision += 1;
    record.reconciled_unix_seconds = Some(at);
    tx.execute(
        "UPDATE maintenance_state SET restore_json=?1 WHERE id=1",
        [serde_json::to_string(&record)?],
    )?;
    audit(&tx, "baseline_attested_old_windows_frozen", &record, at)?;
    tx.commit()?;
    Ok(record)
}
