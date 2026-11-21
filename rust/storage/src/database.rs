use std::fmt;
use std::fs::File;
use std::io;
use std::path::Path;
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior};
use serde::Deserialize;

use crate::credential::valid_key_id;
use crate::files::{database_file, lock_exclusive, sidecar};
use crate::schema::TABLE_COLUMNS;

pub const SCHEMA_VERSION: i64 = 19;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DatabaseError {
    IncompatibleSchema,
    InstanceLocked,
    IncompleteRestore,
    IncompleteReencryption,
    StorageUnavailable,
}

impl fmt::Display for DatabaseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::IncompatibleSchema => "incompatible SQLite schema",
            Self::InstanceLocked => "database is locked by another instance",
            Self::IncompleteRestore => "database has an incomplete restore",
            Self::IncompleteReencryption => "database has incomplete credential reencryption",
            Self::StorageUnavailable => "SQLite storage unavailable",
        })
    }
}

impl std::error::Error for DatabaseError {}

impl From<rusqlite::Error> for DatabaseError {
    fn from(_: rusqlite::Error) -> Self {
        Self::StorageUnavailable
    }
}

/// Owns the SQLite writer and its Swift-compatible instance lock.
/// The connection closes before the lock file descriptor.
pub struct Database {
    connection: Connection,
    _lock: File,
}

impl Database {
    /// Open an existing v19 database without creating or migrating its schema.
    /// This validates the storage format and maintenance barriers. Runtime recovery
    /// and verification of credentials, policy limits, and readiness are separate.
    pub fn open_existing(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        use DatabaseError::*;

        let path = path.as_ref();
        if path == Path::new(":memory:") {
            return Err(StorageUnavailable);
        }
        let path = path.canonicalize().map_err(|_| StorageUnavailable)?;
        let lock = database_file(&sidecar(&path, ".lock"), true).map_err(|_| StorageUnavailable)?;
        lock_exclusive(&lock).map_err(|error| match error.kind() {
            io::ErrorKind::WouldBlock => InstanceLocked,
            _ => StorageUnavailable,
        })?;
        match sidecar(&path, ".restore-pending").symlink_metadata() {
            Ok(_) => return Err(IncompleteRestore),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return Err(StorageUnavailable),
        }
        database_file(&path, false).map_err(|_| StorageUnavailable)?;
        for suffix in ["-wal", "-shm"] {
            match database_file(&sidecar(&path, suffix), false) {
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => return Err(StorageUnavailable),
            }
        }

        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.busy_timeout(Duration::from_millis(250))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        if pragma_integer(&connection, "busy_timeout")? != 250
            || pragma_integer(&connection, "foreign_keys")? != 1
        {
            return Err(StorageUnavailable);
        }
        if pragma_integer(&connection, "user_version")? != SCHEMA_VERSION {
            return Err(IncompatibleSchema);
        }
        validate_schema(&connection)?;
        if pragma_integer(&connection, "auto_vacuum")? != 2 {
            return Err(StorageUnavailable);
        }
        check_integrity(&connection)?;
        check_reencryption(&connection)?;

        let mode: String = connection.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        if mode != "wal" || pragma_integer(&connection, "synchronous")? != 2 {
            return Err(StorageUnavailable);
        }
        Ok(Self {
            connection,
            _lock: lock,
        })
    }

    /// Borrow the locked writer for adapter queries.
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Reserve the writer before an adapter evaluates the preconditions of a write.
    pub fn begin_immediate(&mut self) -> Result<Transaction<'_>, DatabaseError> {
        Ok(self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?)
    }
}

fn pragma_integer(connection: &Connection, name: &str) -> rusqlite::Result<i64> {
    connection.pragma_query_value(None, name, |row| row.get(0))
}

fn check_integrity(connection: &Connection) -> Result<(), DatabaseError> {
    let mut statement = connection.prepare("PRAGMA quick_check")?;
    let mut rows = statement.query([])?;
    let Some(row) = rows.next()? else {
        return Err(DatabaseError::StorageUnavailable);
    };
    if row.get::<_, String>(0)? != "ok" || rows.next()?.is_some() {
        return Err(DatabaseError::StorageUnavailable);
    }
    Ok(())
}

fn validate_schema(connection: &Connection) -> Result<(), DatabaseError> {
    let mut columns = connection.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")?;
    for &(table, expected) in TABLE_COLUMNS {
        let mut rows = columns.query([table])?;
        for name in expected.split_ascii_whitespace() {
            let Some(row) = rows.next()? else {
                return Err(DatabaseError::IncompatibleSchema);
            };
            if row.get::<_, String>(0)? != name {
                return Err(DatabaseError::IncompatibleSchema);
            }
        }
        if rows.next()?.is_some() {
            return Err(DatabaseError::IncompatibleSchema);
        }
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reencryption {
    #[serde(rename = "jobID")]
    job_id: String,
    #[serde(rename = "backupID")]
    backup_id: String,
    #[serde(rename = "targetKeyID")]
    target_key_id: String,
    started_unix_seconds: i64,
    rewritten: i64,
    complete: bool,
}

fn check_reencryption(connection: &Connection) -> Result<(), DatabaseError> {
    use DatabaseError::*;

    let record: Option<Option<String>> = connection
        .query_row(
            "SELECT CASE WHEN length(CAST(record_json AS BLOB)) <= 8192 THEN record_json END
         FROM maintenance_events WHERE action='credential_reencryption' ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(record) = record {
        let record: Reencryption =
            serde_json::from_str(record.as_deref().ok_or(StorageUnavailable)?)
                .map_err(|_| StorageUnavailable)?;
        if !uuid_shape(&record.job_id)
            || !uuid_shape(&record.backup_id)
            || !valid_key_id(&record.target_key_id)
            || !(1..=1_000_000_000_000).contains(&record.started_unix_seconds)
            || !(0..=64).contains(&record.rewritten)
        {
            return Err(StorageUnavailable);
        }
        if !record.complete {
            return Err(IncompleteReencryption);
        }
    }
    Ok(())
}

fn uuid_shape(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latest_reencryption_checkpoint_controls_open() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("CREATE TABLE maintenance_events(id INTEGER PRIMARY KEY, action TEXT, record_json TEXT)")
            .unwrap();
        let append = |record: &str| {
            connection.execute(
                "INSERT INTO maintenance_events(action,record_json) VALUES('credential_reencryption',?1)",
                [record],
            ).unwrap();
        };
        let mut checkpoint = serde_json::json!({
            "jobID": "00000000-0000-0000-0000-000000000001",
            "backupID": "00000000-0000-0000-0000-000000000002",
            "targetKeyID": "0123456789abcdef0123456789abcdef",
            "startedUnixSeconds": 1,
            "rewritten": 0,
            "complete": false
        });
        assert_eq!(check_reencryption(&connection), Ok(()));
        append(&checkpoint.to_string());
        assert_eq!(
            check_reencryption(&connection),
            Err(DatabaseError::IncompleteReencryption)
        );
        checkpoint["complete"] = true.into();
        append(&checkpoint.to_string());
        assert_eq!(check_reencryption(&connection), Ok(()));
        append("{}");
        assert_eq!(
            check_reencryption(&connection),
            Err(DatabaseError::StorageUnavailable)
        );
    }
}
