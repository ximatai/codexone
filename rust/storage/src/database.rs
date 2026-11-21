use std::fmt;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

use crate::credential::valid_key_id;
use crate::files::{database_file, lock_exclusive, sidecar};
use crate::migration::{backup_before_upgrade, require_capacity};
use crate::schema::{TABLE_COLUMNS, apply_migrations};

pub const SCHEMA_VERSION: i64 = 19;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DatabaseError {
    IncompatibleSchema,
    InstanceLocked,
    IncompleteRestore,
    IncompleteReencryption,
    StoragePressure,
    MigrationBackupFailed,
    MigrationTransactionFailed,
    StorageUnavailable,
}

impl fmt::Display for DatabaseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::IncompatibleSchema => "incompatible SQLite schema",
            Self::InstanceLocked => "database is locked by another instance",
            Self::IncompleteRestore => "database has an incomplete restore",
            Self::IncompleteReencryption => "database has incomplete credential reencryption",
            Self::StoragePressure => "insufficient free space for database migration",
            Self::MigrationBackupFailed => "could not publish the pre-migration backup",
            Self::MigrationTransactionFailed => "database migration transaction failed",
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
    lock: Arc<File>,
    path: PathBuf,
}

/// A path covered by the writer's existing instance lock while a backup runs.
/// The lock is shared even if an unexpected writer exit closes its SQLite connection.
pub struct DatabaseBackupSource {
    _lock: Arc<File>,
    path: PathBuf,
}

impl DatabaseBackupSource {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum OpenMode {
    Existing,
    CredentialMaintenance,
    RestoreStaging,
    KeyImport,
    Startup,
    Migrate,
}

impl Database {
    /// Open an existing v19 database without creating or migrating its schema.
    /// This validates the storage format and maintenance barriers. Runtime recovery
    /// and verification of credentials, policy limits, and readiness are separate.
    pub fn open_existing(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        Self::open(path.as_ref(), OpenMode::Existing)
    }

    /// Open an existing database for inspecting or resuming a credential job.
    /// A malformed checkpoint or pending restore still prevents this open.
    pub fn open_for_credential_maintenance(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        Self::open(path.as_ref(), OpenMode::CredentialMaintenance)
    }

    /// Open an empty or current database for a managed-Key import. Older schemas
    /// require an explicit migration.
    pub fn open_for_key_import(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        Self::open(path.as_ref(), OpenMode::KeyImport)
    }

    /// Prepare a private staging copy for restore. The original verified bundle is
    /// the pre-upgrade backup, so no raw migration backup is created.
    pub fn open_restore_staging(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        Self::open(path.as_ref(), OpenMode::RestoreStaging)
    }

    /// Create a v19 database or open an existing one for service startup.
    /// Automatically upgrades v12–v18 when the Swift startup conditions are met.
    pub fn open_or_create(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        Self::open(path.as_ref(), OpenMode::Startup)
    }

    /// Offline upgrade of an existing v1–v18 database, with a durable pre-upgrade
    /// backup. A compatible v19 database needs no schema changes or backup.
    /// Execution recovery and credential maintenance remain separate operations.
    pub fn migrate(path: impl AsRef<Path>) -> Result<(), DatabaseError> {
        drop(Self::open(path.as_ref(), OpenMode::Migrate)?);
        Ok(())
    }

    fn open(path: &Path, mode: OpenMode) -> Result<Self, DatabaseError> {
        use DatabaseError::*;

        let create = matches!(mode, OpenMode::Startup | OpenMode::KeyImport);
        let path = canonical_database_path(path, create).map_err(|_| StorageUnavailable)?;
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
        database_file(&path, create).map_err(|_| StorageUnavailable)?;
        for suffix in ["-wal", "-shm"] {
            match database_file(&sidecar(&path, suffix), false) {
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => return Err(StorageUnavailable),
            }
        }

        let mut connection = Connection::open_with_flags(&path, WRITER_FLAGS)?;
        connection.busy_timeout(Duration::from_millis(250))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        if pragma_integer(&connection, "busy_timeout")? != 250
            || pragma_integer(&connection, "foreign_keys")? != 1
        {
            return Err(StorageUnavailable);
        }
        let version = pragma_integer(&connection, "user_version")?;
        let supported = match mode {
            OpenMode::Existing | OpenMode::CredentialMaintenance => version == SCHEMA_VERSION,
            OpenMode::KeyImport => version == 0 || version == SCHEMA_VERSION,
            OpenMode::RestoreStaging => (7..=SCHEMA_VERSION).contains(&version),
            OpenMode::Startup => version == 0 || (12..=SCHEMA_VERSION).contains(&version),
            OpenMode::Migrate => (1..=SCHEMA_VERSION).contains(&version),
        };
        if !supported {
            return Err(IncompatibleSchema);
        }
        if version == 0 {
            let objects: i64 = connection.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'",
                [],
                |row| row.get(0),
            )?;
            if objects != 0 {
                return Err(IncompatibleSchema);
            }
            connection.pragma_update(None, "auto_vacuum", "INCREMENTAL")?;
        } else {
            validate_schema(&connection, version)?;
            let incremental = pragma_integer(&connection, "auto_vacuum")? == 2;
            if version == SCHEMA_VERSION && !incremental {
                return Err(StorageUnavailable);
            }
            if version < SCHEMA_VERSION && mode == OpenMode::Startup && !incremental {
                return Err(IncompatibleSchema);
            }
            check_integrity(&connection)?;
            // The Swift offline migration changes schema only; service opens honor
            // the credential barrier before making any migration changes.
            match mode {
                OpenMode::Migrate => {}
                OpenMode::CredentialMaintenance => {
                    reencryption_checkpoint(&connection)?;
                }
                _ => check_reencryption(&connection)?,
            }
        }

        let upgrading = (1..SCHEMA_VERSION).contains(&version);
        let directory = path.parent().ok_or(StorageUnavailable)?;
        if upgrading && mode == OpenMode::Startup {
            require_capacity(directory, &connection, 3, 16)?;
        }
        let journal: String =
            connection.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        if journal != "wal" || pragma_integer(&connection, "synchronous")? != 2 {
            return Err(StorageUnavailable);
        }
        if upgrading {
            if mode != OpenMode::RestoreStaging {
                backup_before_upgrade(&path, directory, &connection, version).map_err(|error| {
                    if mode == OpenMode::Startup && error == StorageUnavailable {
                        MigrationBackupFailed
                    } else {
                        error
                    }
                })?;
            }
            require_capacity(directory, &connection, 2, 8)?;
            if pragma_integer(&connection, "auto_vacuum")? != 2 {
                connection.execute_batch("PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")?;
            }
        }
        if version != SCHEMA_VERSION {
            update_schema(&mut connection, version).map_err(|error| {
                if upgrading && mode == OpenMode::Startup && error == StorageUnavailable {
                    MigrationTransactionFailed
                } else {
                    error
                }
            })?;
        }
        Ok(Self {
            connection,
            lock: Arc::new(lock),
            path,
        })
    }

    /// The canonical path protected by this database's instance lock.
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn backup_source(&self) -> DatabaseBackupSource {
        DatabaseBackupSource {
            _lock: self.lock.clone(),
            path: self.path.clone(),
        }
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

pub(crate) const WRITER_FLAGS: OpenFlags = OpenFlags::SQLITE_OPEN_READ_WRITE
    .union(OpenFlags::SQLITE_OPEN_NO_MUTEX)
    .union(OpenFlags::SQLITE_OPEN_NOFOLLOW);

fn canonical_database_path(path: &Path, create: bool) -> io::Result<PathBuf> {
    if path == Path::new(":memory:") {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    match path.canonicalize() {
        Ok(canonical) => Ok(canonical),
        Err(error) if create && error.kind() == io::ErrorKind::NotFound => {
            let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
            let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
            let parent = if parent.as_os_str().is_empty() {
                Path::new(".")
            } else {
                parent
            };
            Ok(parent.canonicalize()?.join(name))
        }
        Err(error) => Err(error),
    }
}

fn update_schema(connection: &mut Connection, version: i64) -> Result<(), DatabaseError> {
    use DatabaseError::StorageUnavailable;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| StorageUnavailable)?
        .as_secs() as i64;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    apply_migrations(&transaction, version, SCHEMA_VERSION, now)?;
    validate_schema(&transaction, SCHEMA_VERSION)?;
    if pragma_integer(&transaction, "auto_vacuum")? != 2 {
        return Err(StorageUnavailable);
    }
    check_integrity(&transaction)?;
    transaction.commit()?;
    Ok(())
}

pub(crate) fn pragma_integer(connection: &Connection, name: &str) -> rusqlite::Result<i64> {
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

fn validate_schema(connection: &Connection, version: i64) -> Result<(), DatabaseError> {
    let mut columns = connection.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")?;
    for &(table, groups) in TABLE_COLUMNS {
        if groups[0].0 > version {
            continue;
        }
        let expected = groups
            .iter()
            .take_while(|(introduced, _)| *introduced <= version)
            .flat_map(|(_, names)| names.split_ascii_whitespace());
        let mut rows = columns.query([table])?;
        for name in expected {
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

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReencryptionCheckpoint {
    #[serde(rename = "jobID")]
    pub job_id: String,
    #[serde(rename = "backupID")]
    pub backup_id: String,
    #[serde(rename = "targetKeyID")]
    pub target_key_id: String,
    pub started_unix_seconds: i64,
    pub rewritten: i64,
    pub complete: bool,
}

impl ReencryptionCheckpoint {
    pub fn validate(&self) -> Result<(), DatabaseError> {
        if !uuid_shape(&self.job_id)
            || !uuid_shape(&self.backup_id)
            || !valid_key_id(&self.target_key_id)
            || !(1..=1_000_000_000_000).contains(&self.started_unix_seconds)
            || !(0..=64).contains(&self.rewritten)
        {
            return Err(DatabaseError::StorageUnavailable);
        }
        Ok(())
    }
}

/// Read the last durable checkpoint. Schema versions 7 and later have this audit table.
pub fn reencryption_checkpoint(
    connection: &Connection,
) -> Result<Option<ReencryptionCheckpoint>, DatabaseError> {
    use DatabaseError::StorageUnavailable;

    let record: Option<Option<String>> = connection
        .query_row(
            "SELECT CASE WHEN length(CAST(record_json AS BLOB)) <= 8192 THEN record_json END
             FROM maintenance_events WHERE action='credential_reencryption' ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    record
        .map(|record| {
            let record: ReencryptionCheckpoint =
                serde_json::from_str(record.as_deref().ok_or(StorageUnavailable)?)
                    .map_err(|_| StorageUnavailable)?;
            record.validate()?;
            Ok(record)
        })
        .transpose()
}

fn check_reencryption(connection: &Connection) -> Result<(), DatabaseError> {
    if reencryption_checkpoint(connection)?.is_some_and(|job| !job.complete) {
        return Err(DatabaseError::IncompleteReencryption);
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
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

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

    fn legacy(path: &Path, version: i64, incremental: bool) -> Connection {
        let connection = Connection::open(path).unwrap();
        if incremental {
            connection
                .pragma_update(None, "auto_vacuum", "INCREMENTAL")
                .unwrap();
        }
        apply_migrations(&connection, 0, version, 200).unwrap();
        connection
    }

    fn backups(directory: &Path, version: i64) -> Vec<PathBuf> {
        let prefix = format!("source.sqlite.pre-v{}-", (version + 1).max(13));
        fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(&prefix)
            })
            .inspect(|path| {
                assert_eq!(path.extension().unwrap(), "sqlite");
                assert_eq!(path.metadata().unwrap().permissions().mode() & 0o777, 0o600);
            })
            .collect()
    }

    #[test]
    fn upgrades_each_supported_version_through_its_startup_or_offline_entry() {
        for version in 1..SCHEMA_VERSION {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("source.sqlite");
            let seed = legacy(&path, version, version >= 12);
            seed.execute("INSERT INTO metadata VALUES(1,'synthetic')", [])
                .unwrap();
            drop(seed);
            assert_eq!(
                Database::open_existing(&path).err(),
                Some(DatabaseError::IncompatibleSchema)
            );
            if version < 12 {
                assert_eq!(
                    Database::open_or_create(&path).err(),
                    Some(DatabaseError::IncompatibleSchema)
                );
                assert!(backups(directory.path(), version).is_empty());
                Database::migrate(&path).unwrap();
            } else {
                drop(Database::open_or_create(&path).unwrap());
            }
            let current = Database::open_existing(&path).unwrap();
            assert_eq!(
                pragma_integer(current.connection(), "auto_vacuum").unwrap(),
                2
            );
            assert_eq!(
                current
                    .connection()
                    .query_row("SELECT limits_json FROM metadata", [], |row| row
                        .get::<_, String>(0))
                    .unwrap(),
                "synthetic"
            );
            drop(current);
            Database::migrate(&path).unwrap();

            let snapshots = backups(directory.path(), version);
            assert_eq!(snapshots.len(), 1);
            let snapshot =
                Connection::open_with_flags(&snapshots[0], OpenFlags::SQLITE_OPEN_READ_ONLY)
                    .unwrap();
            assert_eq!(pragma_integer(&snapshot, "user_version").unwrap(), version);
            assert_eq!(
                pragma_integer(&snapshot, "auto_vacuum").unwrap(),
                if version < 12 { 0 } else { 2 }
            );
            assert_eq!(
                snapshot
                    .pragma_query_value(None, "journal_mode", |row| row.get::<_, String>(0))
                    .unwrap(),
                "delete"
            );
            assert_eq!(
                snapshot
                    .query_row("SELECT limits_json FROM metadata", [], |row| row
                        .get::<_, String>(0))
                    .unwrap(),
                "synthetic"
            );
        }
    }

    #[test]
    fn offline_migration_preserves_wal_rows_and_backfills_v11_price_coverage() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("source.sqlite");
        let seed = legacy(&path, 11, true);
        seed.pragma_update(None, "journal_mode", "WAL").unwrap();
        seed.execute_batch(
            "PRAGMA wal_autocheckpoint=0;
             INSERT INTO usage_daily(day_epoch,key_id,model,mode,outcome,failure,completeness,
               usage_unknown,requests,last_used_epoch)
             VALUES(0,'k','m','generation','succeeded','','complete',0,2,30),
                   (0,'k','m','generation','succeeded','','partial',0,3,30);",
        )
        .unwrap();
        assert!(sidecar(&path, "-wal").metadata().unwrap().len() > 0);
        Database::migrate(&path).unwrap();
        drop(seed);

        let snapshots = backups(directory.path(), 11);
        let source =
            Connection::open_with_flags(&snapshots[0], OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(
            source
                .query_row("SELECT count(*) FROM usage_daily", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            2
        );
        let upgraded = Database::open_existing(&path).unwrap();
        let mut statement = upgraded
            .connection()
            .prepare("SELECT price_unknown FROM usage_daily ORDER BY completeness")
            .unwrap();
        let rows = statement
            .query_map([], |row| row.get::<_, i64>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert_eq!(rows, [0, 3]);
    }

    #[test]
    fn startup_failure_rolls_back_schema_and_retains_backup_for_retry() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("source.sqlite");
        let connection = legacy(&path, 13, true);
        connection
            .execute_batch("CREATE TABLE model_directory(unrelated TEXT);")
            .unwrap();
        drop(connection);
        assert_eq!(
            Database::open_or_create(&path).err(),
            Some(DatabaseError::MigrationTransactionFailed)
        );

        let connection = Connection::open(&path).unwrap();
        assert_eq!(pragma_integer(&connection, "user_version").unwrap(), 13);
        validate_schema(&connection, 13).unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE name='account_credit_samples'",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        assert_eq!(backups(directory.path(), 13).len(), 1);
        connection
            .execute_batch("DROP TABLE model_directory;")
            .unwrap();
        drop(connection);
        drop(Database::open_or_create(&path).unwrap());
        assert_eq!(backups(directory.path(), 13).len(), 2);
    }

    #[test]
    fn startup_rejects_ineligible_sources_before_creating_a_backup() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("source.sqlite");
        let seed = legacy(&path, 18, false);
        drop(seed);
        assert_eq!(
            Database::open_or_create(&path).err(),
            Some(DatabaseError::IncompatibleSchema)
        );
        let seed = Connection::open(&path).unwrap();
        seed.execute_batch(
            r#"PRAGMA auto_vacuum=INCREMENTAL;
               VACUUM;
               INSERT INTO maintenance_events(action,record_json,at_epoch)
               VALUES('credential_reencryption','{
                 "jobID":"00000000-0000-0000-0000-000000000001",
                 "backupID":"00000000-0000-0000-0000-000000000002",
                 "targetKeyID":"0123456789abcdef0123456789abcdef",
                 "startedUnixSeconds":1,"rewritten":0,"complete":false
               }',1);"#,
        )
        .unwrap();
        drop(seed);
        assert_eq!(
            Database::open_or_create(&path).err(),
            Some(DatabaseError::IncompleteReencryption)
        );
        assert!(backups(directory.path(), 18).is_empty());
        Database::migrate(&path).unwrap();
        assert_eq!(backups(directory.path(), 18).len(), 1);
        assert_eq!(
            Database::open_existing(&path).err(),
            Some(DatabaseError::IncompleteReencryption)
        );
    }
}
