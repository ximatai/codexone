use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

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
    backup_checked(
        db,
        database,
        destination,
        protection,
        &mut SnapshotCheck::default(),
    )
}

/// The callback is shared with SQLite's VM progress handler on the private snapshot connection.
#[derive(Default)]
pub(crate) struct SnapshotCheck {
    poll: Option<Arc<dyn Fn() -> Result<()> + Send + Sync>>,
    #[cfg(feature = "backup-test-support")]
    pub(crate) after_first_batch: Option<Box<dyn FnOnce() + Send>>,
    #[cfg(test)]
    after_copy_batch: Option<Box<dyn FnOnce() -> Result<()> + Send>>,
}

impl SnapshotCheck {
    pub(crate) fn online(poll: impl Fn() -> Result<()> + Send + Sync + 'static) -> Self {
        Self {
            poll: Some(Arc::new(poll)),
            #[cfg(feature = "backup-test-support")]
            after_first_batch: None,
            #[cfg(test)]
            after_copy_batch: None,
        }
    }

    pub(crate) fn run(&self) -> Result<()> {
        match &self.poll {
            Some(check) => check(),
            None => Ok(()),
        }
    }

    fn watch(&self, connection: &mut Connection) -> Result<()> {
        if let Some(check) = self.poll.clone() {
            connection.progress_handler(1000, Some(move || check().is_err()))?;
        }
        Ok(())
    }
}

pub(crate) fn backup_checked(
    db: &Connection,
    database: &Path,
    destination: &Path,
    protection: Option<&AccountCredentialCipher>,
    check: &mut SnapshotCheck,
) -> Result<SnapshotManifest> {
    check.run()?;
    require_complete_reencryption(db)?;
    require_reconciled_source(db)?;
    if check.poll.is_none() {
        verify_credentials(db, protection)?;
    }
    let destination = files::normalized_leaf(destination)?;
    let parent = files::parent(&destination)?;
    require_free_space(parent, snapshot_bytes(db)? + 8 * MIB, true)?;
    require_free_space(files::parent(database)?, 8 * MIB, true)?;
    match files::create_directory(&destination) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => return Err(Error::Conflict),
        Err(error) => return Err(error.into()),
    }
    let result = write_bundle(db, &destination, protection, check);
    if result.is_err() && check.poll.is_none() && fs::remove_dir_all(&destination).is_ok() {
        // Only clean up a directory this invocation created. Online partials belong
        // to the scheduled worker and are retired on its next normal pass.
        let _ = files::sync_directory(parent);
    }
    result
}

fn write_bundle(
    db: &Connection,
    destination: &Path,
    protection: Option<&AccountCredentialCipher>,
    check: &mut SnapshotCheck,
) -> Result<SnapshotManifest> {
    files::private_directory(destination)?;
    let partial = destination.join("snapshot.sqlite.partial");
    copy(db, &partial, true, check)?;
    check.run()?;
    let mut copy = open_snapshot(&partial)?;
    check.watch(&mut copy)?;
    let keys = verify_credentials(&copy, protection)?;
    require_integrity(&copy)?;
    let generation = generation(&copy)?;
    let schema = copy.pragma_query_value(None, "user_version", |row| row.get(0))?;
    drop(copy);

    let (bytes, hash) = files::fingerprint_checked(&partial, || check.run())?;
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

    check.run()?;
    fs::rename(partial, destination.join("snapshot.sqlite"))?;
    files::write_synced(&destination.join("snapshot.sqlite.lock"), b"")?;
    let manifest_partial = destination.join("manifest.partial");
    files::write_synced(&manifest_partial, &serde_json::to_vec(&manifest)?)?;
    fs::rename(manifest_partial, destination.join("manifest.json"))?;
    files::sync_directory(destination)?;
    files::sync_directory(files::parent(destination)?)?;
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
    check: &SnapshotCheck,
) -> Result<VerifiedSnapshot> {
    let bundle = files::normalized_leaf(bundle)?;
    files::private_directory(&bundle)?;
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
    require_fingerprint(&path, &manifest, check)?;
    let mut source = open_snapshot(&path)?;
    check.watch(&mut source)?;
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
    verify_backup_checked(bundle, protection, &SnapshotCheck::default())
}

pub(crate) fn verify_backup_checked(
    bundle: &Path,
    protection: Option<&AccountCredentialCipher>,
    check: &SnapshotCheck,
) -> Result<SnapshotManifest> {
    Ok(verified_snapshot(bundle, protection, check)?.manifest)
}

pub(crate) fn restore(
    bundle: &Path,
    path: &Path,
    protection: Option<&AccountCredentialCipher>,
    day: BusinessDay,
) -> Result<RestoreRecord> {
    restore_with_barrier(
        bundle,
        path,
        protection,
        day,
        SnapshotCheck::default(),
        || Ok(()),
    )
}

fn restore_with_barrier(
    bundle: &Path,
    path: &Path,
    protection: Option<&AccountCredentialCipher>,
    day: BusinessDay,
    mut check: SnapshotCheck,
    barrier_written: impl FnOnce() -> Result<()>,
) -> Result<RestoreRecord> {
    let verified = verified_snapshot(bundle, protection, &check)?;
    let manifest = &verified.manifest;
    let previous = require_reconciled_source(&verified.source)?;
    let directory = files::normalized_leaf(files::parent(path)?)?;
    let parent = files::parent(&directory)?;
    let capacity_path = match directory.symlink_metadata() {
        Ok(_) => {
            files::private_directory(&directory)?;
            directory.as_path()
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => parent,
        Err(error) => return Err(error.into()),
    };
    require_free_space(capacity_path, manifest.database_bytes + 8 * MIB, false)?;
    match files::create_directory(&directory) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    files::private_directory(&directory)?;
    files::sync_directory(parent)?;
    let path = directory.join(path.file_name().ok_or(Error::Invalid)?);
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
    files::sync_directory(&directory)?;
    barrier_written()?;

    let staging = files::sidecar(&path, ".restoring.partial");
    copy(&verified.source, &staging, false, &mut check)?;
    require_fingerprint(&verified.path, manifest, &check)?;

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
    files::sync_directory(&directory)?;
    fs::remove_file(barrier)?;
    files::sync_directory(&directory)?;
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

fn require_fingerprint(
    path: &Path,
    manifest: &SnapshotManifest,
    check: &SnapshotCheck,
) -> Result<()> {
    let (size, hash) = files::fingerprint_checked(path, || check.run())?;
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

fn copy(source: &Connection, path: &Path, optional: bool, check: &mut SnapshotCheck) -> Result<()> {
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
        let online = check.poll.is_some();
        let deadline = Instant::now() + Duration::from_secs(300);
        let page_size: i64 = source.pragma_query_value(None, "page_size", |row| row.get(0))?;
        let transfer = Backup::new(source, &mut target)?;
        loop {
            check.run()?;
            if online && Instant::now() >= deadline {
                return Err(Error::Storage);
            }
            require_free_space(directory, 2 * MIB, optional)?;
            let step = transfer.step(128)?;
            #[cfg(test)]
            if matches!(step, StepResult::More)
                && let Some(after_batch) = check.after_copy_batch.take()
            {
                after_batch()?;
            }
            if i64::from(transfer.progress().pagecount) > MAX_DATABASE_BYTES / page_size {
                return Err(Error::Capacity);
            }
            match step {
                StepResult::Done => break,
                StepResult::More if online => {
                    #[cfg(feature = "backup-test-support")]
                    if let Some(after_first_batch) = check.after_first_batch.take() {
                        after_first_batch();
                    }
                    thread::sleep(Duration::from_millis(1));
                }
                StepResult::More => {}
                StepResult::Busy | StepResult::Locked if online => {
                    thread::sleep(Duration::from_millis(10));
                }
                _ => return Err(Error::Storage),
            }
        }
    }
    check.run()?;
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
    fn offline_backup_removes_its_bundle_when_snapshot_validation_fails() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("core.sqlite");
        let db = Database::open_or_create(&source).unwrap();
        db.connection()
            .execute_batch(
                "PRAGMA foreign_keys = OFF;
                 CREATE TABLE synthetic_parent(id INTEGER PRIMARY KEY);
                 CREATE TABLE synthetic_child(parent INTEGER REFERENCES synthetic_parent);
                 INSERT INTO synthetic_child VALUES(1);",
            )
            .unwrap();
        let bundle = temporary.path().join("bundle");
        assert!(matches!(
            backup_locked(db.connection(), db.path(), &bundle, None),
            Err(Error::Invalid)
        ));
        assert!(!bundle.exists());
    }

    #[test]
    fn interrupted_restore_leaves_a_barrier_before_any_target_page() {
        let temporary = tempfile::tempdir().unwrap();
        let workspace = temporary.path().canonicalize().unwrap();
        let source = workspace.join("core.sqlite");
        drop(Database::open_or_create(&source).unwrap());
        let bundle = workspace.join("bundle");
        let manifest = backup(&source, &bundle, None).unwrap();
        let target = workspace.join("restored/core.sqlite");

        let error = restore_with_barrier(
            &bundle,
            &target,
            None,
            BusinessDay::new(0).unwrap(),
            SnapshotCheck::default(),
            || {
                assert_eq!(
                    fs::read(files::sidecar(&target, ".restore-pending")).unwrap(),
                    manifest.id.as_bytes()
                );
                assert!(!target.exists());
                assert!(!files::sidecar(&target, ".restoring.partial").exists());
                Err(Error::Storage)
            },
        );
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

    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "requires CODEXONE_TEST_TMPFS to point to an empty private 384–512 MiB tmpfs mount"]
    fn restore_rechecks_capacity_between_copy_batches() {
        use std::io::Write;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::MetadataExt;

        fn tmpfs_space(directory: &File) -> (u64, u64) {
            let mut stat = std::mem::MaybeUninit::<libc::statfs>::uninit();
            // SAFETY: The directory FD is open and stat points to writable storage.
            assert_eq!(
                unsafe { libc::fstatfs(directory.as_raw_fd(), stat.as_mut_ptr()) },
                0
            );
            // SAFETY: fstatfs succeeded and initialized stat.
            let stat = unsafe { stat.assume_init() };
            assert_eq!(stat.f_type, libc::TMPFS_MAGIC);
            let block_bytes = stat.f_bsize as u64;
            (stat.f_blocks * block_bytes, stat.f_bavail * block_bytes)
        }

        let volume = PathBuf::from(std::env::var_os("CODEXONE_TEST_TMPFS").unwrap())
            .canonicalize()
            .unwrap();
        files::private_directory(&volume).unwrap();
        assert_ne!(
            volume.metadata().unwrap().dev(),
            volume.parent().unwrap().metadata().unwrap().dev()
        );
        assert!(volume.read_dir().unwrap().next().is_none());
        let directory = File::open(&volume).unwrap();
        assert!((384 * MIB as u64..=512 * MIB as u64).contains(&tmpfs_space(&directory).0));

        let source = tempfile::tempdir().unwrap();
        let database = source.path().join("core.sqlite");
        let db = Database::open_or_create(&database).unwrap();
        db.connection()
            .execute_batch(
                "CREATE TABLE synthetic_pages(payload BLOB);
                 INSERT INTO synthetic_pages VALUES(zeroblob(4194304));",
            )
            .unwrap();
        drop(db);
        let bundle = source.path().join("bundle");
        let manifest = backup(&database, &bundle, None).unwrap();
        let scratch = tempfile::tempdir_in(&volume).unwrap();
        let target = scratch.path().join("restore/core.sqlite");
        let filler = scratch.path().join("synthetic-filler");
        let day = BusinessDay::new(0).unwrap();

        let staging = files::sidecar(&target, ".restoring.partial");
        let after_copy_batch = {
            let filler = filler.clone();
            let staging = staging.clone();
            let target = target.clone();
            let backup_id = manifest.id.clone();
            move || {
                assert_eq!(
                    fs::read(files::sidecar(&target, ".restore-pending")).unwrap(),
                    backup_id.as_bytes()
                );
                assert!(staging.exists() && !target.exists());
                let mut file = files::new_file(&filler).unwrap();
                let block = vec![0; MIB as usize];
                let bytes_to_use = tmpfs_space(&directory).1.saturating_sub(100 * MIB as u64);
                for _ in 0..bytes_to_use / MIB as u64 {
                    file.write_all(&block).unwrap();
                }
                file.sync_all().unwrap();
                Ok(())
            }
        };
        let result = restore_with_barrier(
            &bundle,
            &target,
            None,
            day,
            SnapshotCheck {
                after_copy_batch: Some(Box::new(after_copy_batch)),
                ..SnapshotCheck::default()
            },
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(Error::Database(DatabaseError::StoragePressure))
        ));
        assert!(!target.exists());
        assert!(staging.exists());
        assert_eq!(
            Database::open_or_create(&target).err(),
            Some(DatabaseError::IncompleteRestore)
        );
        assert_eq!(verify_backup(&bundle, None).unwrap(), manifest);
        fs::remove_file(filler).unwrap();
        assert!(matches!(
            restore(&bundle, &target, None, day),
            Err(Error::Conflict)
        ));
        assert!(restore(&bundle, &scratch.path().join("clean/core.sqlite"), None, day).is_ok());
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
