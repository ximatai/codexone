//! Swift-compatible snapshot, scheduling, and offline master-key maintenance.

mod files;
mod keys;
mod managed_keys;
pub mod online;
mod record;
mod snapshot;

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use codexone_storage::{AccountCredentialCipher, DatabaseError, reencryption_checkpoint};
use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::Value;

pub use record::{RestoreBaseline, RestoreRecord, RestoreStatus};
pub use snapshot::SnapshotManifest;

/// Stable diagnostics omit filesystem paths, SQLite values and credential data.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Database(#[from] DatabaseError),
    #[error("maintenance storage unavailable")]
    Storage,
    #[error("invalid maintenance input or record")]
    Invalid,
    #[error("maintenance capacity exceeded")]
    Capacity,
    #[error("maintenance operation conflicts with existing state")]
    Conflict,
    #[error("restore has not been reconciled")]
    Unreconciled,
    #[error("credential validation failed or master key is missing")]
    Credential,
    #[error("resume requires the original target key as the active key")]
    WrongActiveKey,
    #[error("retained backups require matching restore evidence")]
    MissingRestoreEvidence,
}

type Result<T> = std::result::Result<T, Error>;

impl From<std::io::Error> for Error {
    fn from(_: std::io::Error) -> Self {
        Self::Storage
    }
}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Storage
    }
}

impl From<serde_json::Error> for Error {
    fn from(_: serde_json::Error) -> Self {
        Self::Invalid
    }
}

impl From<codexone_storage::CredentialError> for Error {
    fn from(_: codexone_storage::CredentialError) -> Self {
        Self::Credential
    }
}

pub enum Command {
    ImportKeys(PathBuf),
    Backup(PathBuf),
    VerifyBackup(PathBuf),
    Restore(PathBuf),
    Status,
    Reconcile(PathBuf),
    KeyStatus,
    Reencrypt(PathBuf),
    ResumeReencryption,
    CheckKeyRetirement(PathBuf),
}

impl Command {
    pub fn parse(arguments: &[String]) -> Option<Self> {
        match arguments {
            [flag] if flag == "--maintenance-status" => Some(Self::Status),
            [flag] if flag == "--key-status" => Some(Self::KeyStatus),
            [flag] if flag == "--resume-reencryption" => Some(Self::ResumeReencryption),
            [flag, argument] if Path::new(argument).is_absolute() && !argument.contains('\0') => {
                let path = PathBuf::from(argument);
                match flag.as_str() {
                    "--import-keys" => Some(Self::ImportKeys(path)),
                    "--backup" => Some(Self::Backup(path)),
                    "--verify-backup" => Some(Self::VerifyBackup(path)),
                    "--restore" => Some(Self::Restore(path)),
                    "--reconcile-restored" => Some(Self::Reconcile(path)),
                    "--reencrypt-credentials" => Some(Self::Reencrypt(path)),
                    "--check-key-retirement" => Some(Self::CheckKeyRetirement(path)),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Runs offline on the calling thread and returns the Swift CLI JSON payload.
    pub fn run(
        self,
        database: &Path,
        protection: Option<&AccountCredentialCipher>,
        business_day_offset_minutes: i16,
        admin_digest: Option<&[u8; 32]>,
    ) -> Result<Value> {
        let day = record::BusinessDay::new(business_day_offset_minutes)?;
        let key = || protection.ok_or(Error::Credential);
        Ok(match self {
            Self::ImportKeys(path) => serde_json::to_value(managed_keys::import(
                database,
                &path,
                admin_digest.ok_or(Error::Credential)?,
            )?)?,
            Self::Backup(path) => {
                serde_json::to_value(snapshot::backup(database, &path, protection)?)?
            }
            Self::VerifyBackup(path) => {
                serde_json::to_value(snapshot::verify_backup(&path, protection)?)?
            }
            Self::Restore(path) => serde_json::to_value(RestoreStatus::new(
                Some(snapshot::restore(&path, database, protection, day)?),
                day,
            )?)?,
            Self::Status => {
                serde_json::to_value(RestoreStatus::new(record::status(database)?, day)?)?
            }
            Self::Reconcile(path) => serde_json::to_value(RestoreStatus::new(
                Some(record::reconcile(database, &path, day)?),
                day,
            )?)?,
            Self::KeyStatus => serde_json::to_value(keys::key_status(database, key()?)?)?,
            Self::Reencrypt(path) => {
                serde_json::to_value(keys::reencrypt(database, key()?, Some(&path))?)?
            }
            Self::ResumeReencryption => {
                serde_json::to_value(keys::reencrypt(database, key()?, None)?)?
            }
            Self::CheckKeyRetirement(path) => {
                serde_json::to_value(keys::check_retirement(database, key()?, &path)?)?
            }
        })
    }
}

const MAX_EPOCH: i64 = 1_000_000_000_000;
const MIB: i64 = 1024 * 1024;
const MAX_DATABASE_BYTES: i64 = 1024 * MIB;

fn now() -> Result<i64> {
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::Invalid)?
        .as_secs();
    if !(1..=MAX_EPOCH as u64).contains(&epoch) {
        return Err(Error::Invalid);
    }
    Ok(epoch as i64)
}

fn new_id(db: &Connection) -> Result<String> {
    Ok(db.query_row(
        "SELECT hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' ||
         substr(hex(randomblob(2)),2) || '-' || substr('89AB',1+(random() & 3),1) ||
         substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))",
        [],
        |row| row.get(0),
    )?)
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(position, byte)| {
            if matches!(position, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn audit_reference(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}

fn audit(db: &Connection, action: &str, record: &impl Serialize, at: i64) -> Result<()> {
    let count: i64 = db.query_row(
        "SELECT COUNT(*) FROM maintenance_events WHERE action!='release_unknown'",
        [],
        |row| row.get(0),
    )?;
    if count >= 1000 {
        return Err(Error::Capacity);
    }
    db.execute(
        "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES(?,?,?)",
        params![action, serde_json::to_string(record)?, at],
    )?;
    Ok(())
}

fn require_complete_reencryption(db: &Connection) -> Result<()> {
    if reencryption_checkpoint(db)?.is_some_and(|job| !job.complete) {
        return Err(DatabaseError::IncompleteReencryption.into());
    }
    Ok(())
}
