use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use codexone_storage::{AccountCredentialCipher, Database, SCHEMA_VERSION, require_free_space};
use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};

use crate::files;
use crate::keys::verify_credentials;
use crate::record::{BusinessDay, RestoreRecord, read_record};
use crate::{
    Error, MAX_DATABASE_BYTES, MIB, Result, audit, is_uuid, new_id, now,
    require_complete_reencryption,
};

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotManifest {
    pub format: i64,
    pub id: String,
    pub created_unix_seconds: i64,
    pub schema: i64,
    pub source_generation: String,
    pub database_bytes: i64,
    #[serde(rename = "databaseSHA256")]
    pub database_sha256: String,
    #[serde(rename = "requiredKeyIDs")]
    pub required_key_ids: Vec<String>,
}

pub(crate) fn backup(
    path: &Path,
    destination: &Path,
    protection: Option<&AccountCredentialCipher>,
) -> Result<SnapshotManifest> {
    let db = Database::open_existing(path)?;
    backup_locked(db.connection(), db.path(), destination, protection)
}

pub(crate) fn backup_locked(
    db: &Connection,
    database: &Path,
    destination: &Path,
    protection: Option<&AccountCredentialCipher>,
) -> Result<SnapshotManifest> {
    require_complete_reencryption(db)?;
    require_reconciled_source(db)?;
    verify_credentials(db, protection)?;
    let parent = files::parent(destination)?.canonicalize()?;
    require_free_space(&parent, snapshot_bytes(db)? + 8 * MIB, true)?;
    require_free_space(files::parent(database)?, 8 * MIB, true)?;
    match files::create_directory(destination) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => return Err(Error::Conflict),
        Err(error) => return Err(error.into()),
    }
    files::private_directory(destination)?;
    let partial = destination.join("snapshot.sqlite.partial");
    copy(db, &partial, true)?;
    let copy = open_snapshot(&partial)?;
    let keys = verify_credentials(&copy, protection)?;
    require_integrity(&copy)?;
    let generation = generation(&copy)?;
    let schema = copy.pragma_query_value(None, "user_version", |row| row.get(0))?;
    drop(copy);

    let (bytes, hash) = files::fingerprint(&partial)?;
    let manifest = SnapshotManifest {
        format: 1,
        id: new_id(db)?,
        created_unix_seconds: now()?,
        schema,
        source_generation: generation,
        database_bytes: bytes,
        database_sha256: hash,
        required_key_ids: keys,
    };

    fs::rename(partial, destination.join("snapshot.sqlite"))?;
    files::write_synced(&destination.join("snapshot.sqlite.lock"), b"")?;
    let manifest_partial = destination.join("manifest.partial");
    files::write_synced(&manifest_partial, &serde_json::to_vec(&manifest)?)?;
    fs::rename(manifest_partial, destination.join("manifest.json"))?;
    files::sync_directory(destination)?;
    files::sync_directory(&parent)?;
    Ok(manifest)
}

struct VerifiedSnapshot {
    manifest: SnapshotManifest,
    source: Connection,
    path: PathBuf,
    _lock: File,
}

fn verified_snapshot(
    bundle: &Path,
    protection: Option<&AccountCredentialCipher>,
) -> Result<VerifiedSnapshot> {
    files::private_directory(bundle)?;
    let path = bundle.join("snapshot.sqlite");
    let lock = files::lock(&files::sidecar(&path, ".lock"), false)?;
    files::require_absent(&path, &["-wal", "-shm", "-journal", ".restore-pending"])?;
    let manifest: SnapshotManifest =
        serde_json::from_slice(&files::read_bounded(&bundle.join("manifest.json"), 8192)?)?;
    if manifest.format != 1
        || !(7..=SCHEMA_VERSION).contains(&manifest.schema)
        || !is_uuid(&manifest.id)
        || !(1..=now()?).contains(&manifest.created_unix_seconds)
        || manifest.source_generation.len() != 32
        || manifest.required_key_ids.len() > 64
        || !(1..=MAX_DATABASE_BYTES).contains(&manifest.database_bytes)
        || manifest.database_sha256.len() != 64
    {
        return Err(Error::Invalid);
    }
    require_fingerprint(&path, &manifest)?;
    let source = open_snapshot(&path)?;
    let schema: i64 = source.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if schema != manifest.schema
        || verify_credentials(&source, protection)? != manifest.required_key_ids
        || generation(&source)? != manifest.source_generation
    {
        return Err(Error::Invalid);
    }
    require_integrity(&source)?;
    require_complete_reencryption(&source)?;
    Ok(VerifiedSnapshot {
        manifest,
        source,
        path,
        _lock: lock,
    })
}

pub(crate) fn verify_backup(
    bundle: &Path,
    protection: Option<&AccountCredentialCipher>,
) -> Result<SnapshotManifest> {
    Ok(verified_snapshot(bundle, protection)?.manifest)
}

pub(crate) fn restore(
    bundle: &Path,
    path: &Path,
    protection: Option<&AccountCredentialCipher>,
    day: BusinessDay,
) -> Result<RestoreRecord> {
    restore_with_barrier(bundle, path, protection, day, || Ok(()))
}

fn restore_with_barrier(
    bundle: &Path,
    path: &Path,
    protection: Option<&AccountCredentialCipher>,
    day: BusinessDay,
    barrier_written: impl FnOnce() -> Result<()>,
) -> Result<RestoreRecord> {
    let verified = verified_snapshot(bundle, protection)?;
    let manifest = &verified.manifest;
    let previous = require_reconciled_source(&verified.source)?;
    let directory = files::parent(path)?;
    let parent = files::parent(directory)?.canonicalize()?;
    let capacity_path = if directory.exists() {
        directory
    } else {
        &parent
    };
    require_free_space(capacity_path, manifest.database_bytes + 8 * MIB, false)?;
    match files::create_directory(directory) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    files::private_directory(directory)?;
    files::sync_directory(&parent)?;
    let path = directory
        .canonicalize()?
        .join(path.file_name().ok_or(Error::Invalid)?);
    let lock_path = files::sidecar(&path, ".lock");
    let _lock = files::lock(&lock_path, true)?;
    for entry in directory.read_dir()? {
        if entry?.file_name() != lock_path.file_name().ok_or(Error::Invalid)? {
            return Err(Error::Conflict);
        }
    }

    // A crash from this point leaves the target closed until an operator disposes of the partial restore.
    let barrier = files::sidecar(&path, ".restore-pending");
    files::write_synced(&barrier, manifest.id.as_bytes())?;
    files::sync_directory(directory)?;
    barrier_written()?;

    let staging = files::sidecar(&path, ".restoring.partial");
    copy(&verified.source, &staging, false)?;
    require_fingerprint(&verified.path, manifest)?;

    let mut target = Database::open_restore_staging(&staging)?;
    let completed = now()?;
    let record = RestoreRecord {
        id: new_id(target.connection())?,
        backup_id: manifest.id.clone(),
        snapshot_unix_seconds: manifest.created_unix_seconds,
        restored_unix_seconds: completed,
        inherited_unresolved_requests: previous
            .as_ref()
            .map_or(0, RestoreRecord::unresolved_requests),
        inherited_unresolved_micros: previous
            .as_ref()
            .map_or(0, RestoreRecord::unresolved_micros),
        inherited_freeze_until_unix_seconds: previous.as_ref().map_or(0, |r| {
            r.baseline
                .as_ref()
                .map_or_else(|| r.minimum_freeze(), |b| b.freeze_until_unix_seconds)
        }),
        day_freeze_until_unix_seconds: day.restore_day_end(completed),
        baseline_revision: 0,
        baseline: None,
        reconciled_unix_seconds: None,
    };
    record.validate()?;
    let tx = target.begin_immediate()?;
    let generation = new_id(&tx)?.replace('-', "").to_ascii_lowercase();
    tx.execute(
        "UPDATE maintenance_state SET generation=?1,restore_json=?2 WHERE id=1",
        params![generation, serde_json::to_string(&record)?],
    )?;
    tx.execute(
        "UPDATE attempts SET state='unknown',unknown_since_epoch=?1 WHERE state='intent'",
        [completed],
    )?;
    tx.execute_batch(
        "DELETE FROM bindings;
         UPDATE accounts SET authorization='requires_auth',refresh_intent=NULL;
         UPDATE account_reset_credits SET record_json=json_set(record_json,'$.settings.autoUseBeforeExpiry',json('false'));
         UPDATE account_quota_priming SET record_json=json_set(record_json,'$.settings.enabled',json('false'));",
    )?;
    crate::managed_keys::disable_all(&tx)?;
    audit(&tx, "restored_unreconciled", &record, completed)?;
    tx.commit()?;

    // Transitioning out of WAL checkpoints the staging database before moving its main file.
    finish_copy(target.connection())?;
    drop(target);
    files::sync_file(&staging)?;
    fs::rename(staging, &path)?;
    files::sync_directory(directory)?;
    fs::remove_file(barrier)?;
    files::sync_directory(directory)?;
    Ok(record)
}

fn generation(db: &Connection) -> Result<String> {
    let generation: String = db.query_row(
        "SELECT CASE WHEN length(CAST(generation AS BLOB))=32 THEN generation END
           FROM maintenance_state WHERE id=1",
        [],
        |row| row.get(0),
    )?;
    Ok(generation)
}

fn require_reconciled_source(db: &Connection) -> Result<Option<RestoreRecord>> {
    let record = read_record(db)?;
    if record
        .as_ref()
        .is_some_and(|record| record.baseline.is_none())
    {
        return Err(Error::Unreconciled);
    }
    Ok(record)
}

fn require_fingerprint(path: &Path, manifest: &SnapshotManifest) -> Result<()> {
    let (size, hash) = files::fingerprint(path)?;
    if size != manifest.database_bytes || hash != manifest.database_sha256 {
        return Err(Error::Invalid);
    }
    Ok(())
}

pub(crate) fn open_snapshot(path: &Path) -> Result<Connection> {
    let source = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    source.busy_timeout(Duration::from_millis(50))?;
    source.pragma_update(None, "query_only", true)?;
    let version: i64 = source.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if !(7..=SCHEMA_VERSION).contains(&version) {
        return Err(Error::Invalid);
    }
    Ok(source)
}

pub(crate) fn require_integrity(source: &Connection) -> Result<()> {
    let mut statement = source.prepare("PRAGMA quick_check")?;
    let mut rows = statement.query([])?;
    if !rows
        .next()?
        .is_some_and(|row| row.get::<_, String>(0).is_ok_and(|result| result == "ok"))
        || rows.next()?.is_some()
        || source.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_foreign_key_check)",
            [],
            |row| row.get::<_, bool>(0),
        )?
    {
        return Err(Error::Invalid);
    }
    Ok(())
}

fn snapshot_bytes(source: &Connection) -> Result<i64> {
    let page_size: i64 = source.pragma_query_value(None, "page_size", |row| row.get(0))?;
    let pages: i64 = source.pragma_query_value(None, "page_count", |row| row.get(0))?;
    pages
        .checked_mul(page_size)
        .filter(|bytes| (1..=MAX_DATABASE_BYTES).contains(bytes))
        .ok_or(Error::Capacity)
}

fn copy(source: &Connection, path: &Path, optional: bool) -> Result<()> {
    let directory = files::parent(path)?;
    let bytes = snapshot_bytes(source)?;
    require_free_space(directory, bytes + 8 * MIB, optional)?;
    let file = files::new_file(path)?;
    let mut target = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    target.busy_timeout(Duration::ZERO)?;
    target.pragma_update(None, "synchronous", "FULL")?;
    {
        let transfer = Backup::new(source, &mut target)?;
        loop {
            require_free_space(directory, 2 * MIB, optional)?;
            match transfer.step(128)? {
                StepResult::Done => break,
                StepResult::More => {}
                _ => return Err(Error::Storage),
            }
        }
    }
    finish_copy(&target)?;
    target.close().map_err(|_| Error::Storage)?;
    file.sync_all()?;
    Ok(())
}

fn finish_copy(target: &Connection) -> Result<()> {
    let journal: String = target.query_row("PRAGMA journal_mode=DELETE", [], |row| row.get(0))?;
    if journal != "delete" {
        return Err(Error::Storage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use codexone_storage::DatabaseError;

    #[test]
    fn interrupted_restore_leaves_a_barrier_before_any_target_page() {
        let temporary = tempfile::tempdir().unwrap();
        let workspace = temporary.path().canonicalize().unwrap();
        let source = workspace.join("core.sqlite");
        drop(Database::open_or_create(&source).unwrap());
        let bundle = workspace.join("bundle");
        let manifest = backup(&source, &bundle, None).unwrap();
        let target = workspace.join("restored/core.sqlite");

        let error =
            restore_with_barrier(&bundle, &target, None, BusinessDay::new(0).unwrap(), || {
                assert_eq!(
                    fs::read(files::sidecar(&target, ".restore-pending")).unwrap(),
                    manifest.id.as_bytes()
                );
                assert!(!target.exists());
                assert!(!files::sidecar(&target, ".restoring.partial").exists());
                Err(Error::Storage)
            });
        assert!(matches!(error, Err(Error::Storage)));
        assert_eq!(
            Database::open_or_create(&target).err(),
            Some(DatabaseError::IncompleteRestore)
        );
        assert!(matches!(
            restore(&bundle, &target, None, BusinessDay::new(0).unwrap()),
            Err(Error::Conflict)
        ));
        assert_eq!(verify_backup(&bundle, None).unwrap(), manifest);
    }

    #[test]
    fn failed_restore_mutations_leave_the_staging_generation_and_audit_unchanged() {
        let temporary = tempfile::tempdir().unwrap();
        let workspace = temporary.path().canonicalize().unwrap();
        let source = workspace.join("core.sqlite");
        let db = Database::open_or_create(&source).unwrap();
        db.connection()
            .execute(
                "INSERT INTO managed_keys VALUES('invalid','synthetic-digest','{}')",
                [],
            )
            .unwrap();
        drop(db);
        let bundle = workspace.join("bundle");
        let manifest = backup(&source, &bundle, None).unwrap();
        let target = workspace.join("restored/core.sqlite");
        assert!(matches!(
            restore(&bundle, &target, None, BusinessDay::new(0).unwrap()),
            Err(Error::Invalid)
        ));
        assert!(!target.exists());
        assert!(files::sidecar(&target, ".restore-pending").exists());
        let staging =
            Database::open_existing(files::sidecar(&target, ".restoring.partial")).unwrap();
        assert_eq!(
            generation(staging.connection()).unwrap(),
            manifest.source_generation
        );
        assert_eq!(read_record(staging.connection()).unwrap(), None);
        assert_eq!(
            staging
                .connection()
                .query_row("SELECT COUNT(*) FROM maintenance_events", [], |row| row
                    .get::<_, i64>(0),)
                .unwrap(),
            0
        );
        assert_eq!(verify_backup(&bundle, None).unwrap(), manifest);
    }
}
