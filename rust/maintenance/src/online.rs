use std::ffi::CString;
use std::fs::{self, DirEntry};
use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use codexone_storage::{AccountCredentialCipher, DatabaseBackupSource, DatabaseError};
use serde::Serialize;

use crate::snapshot::{self, SnapshotCheck, SnapshotManifest};
use crate::{Error, MAX_DATABASE_BYTES, Result, files, is_uuid, new_id, now};

pub const INITIAL_DELAY: Duration = Duration::from_secs(600);
pub const INTERVAL: Duration = Duration::from_secs(86_400);
const RETAINED_BUNDLES: usize = 7;
const MAX_ROOT_ENTRIES: usize = 1024;
const MAX_SCAN_ENTRIES: usize = 16_384;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupObservation {
    pub enabled: bool,
    pub enabled_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_success_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_failure_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_failure: Option<BackupFailure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_skipped_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skipped_pressure: Option<BackupPressure>,
    pub retained_count: usize,
    pub total_bytes: u64,
    pub largest_bundle_bytes: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupFailure {
    DirectoryUnavailable,
    InsufficientSpace,
    SnapshotFailed,
    VerificationFailed,
    RetentionFailed,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupPressure {
    Normal,
    Degraded,
    Blocked,
    Unknown,
}

#[derive(Default)]
struct State {
    observation: Mutex<BackupObservation>,
    cancelled: AtomicBool,
}

/// The status reader does no filesystem or SQLite work.
#[derive(Clone, Default)]
pub struct BackupStatus(Arc<State>);

impl BackupStatus {
    pub fn observation(&self) -> BackupObservation {
        self.0
            .observation
            .lock()
            .expect("backup observation")
            .clone()
    }

    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Relaxed);
    }

    fn update(&self, update: impl FnOnce(&mut BackupObservation)) {
        update(&mut self.0.observation.lock().expect("backup observation"));
    }

    fn cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Relaxed)
    }

    fn failure(&self, failure: BackupFailure) {
        self.update(|status| {
            status.last_failure_unix_seconds = now().ok();
            status.last_failure = Some(failure);
        });
    }
}

/// A single blocking worker with a share of the writer's existing instance lock.
/// The runtime stops and joins this worker before closing the writer.
pub struct OnlineBackup {
    root: PathBuf,
    source: DatabaseBackupSource,
    protection: Option<Arc<AccountCredentialCipher>>,
    status: BackupStatus,
    #[cfg(feature = "backup-test-support")]
    after_first_batch: Option<Box<dyn FnOnce() + Send>>,
}

impl OnlineBackup {
    pub fn new(
        root: PathBuf,
        source: DatabaseBackupSource,
        protection: Option<Arc<AccountCredentialCipher>>,
    ) -> Self {
        let backup = Self {
            root,
            source,
            protection,
            status: BackupStatus::default(),
            #[cfg(feature = "backup-test-support")]
            after_first_batch: None,
        };
        backup.status.update(|status| {
            status.enabled = true;
            status.enabled_unix_seconds = now().unwrap_or(0);
        });
        if backup.refresh_inventory().is_err() {
            backup.status.failure(BackupFailure::VerificationFailed);
        }
        backup
    }

    pub fn status(&self) -> BackupStatus {
        self.status.clone()
    }

    /// Pause a synthetic process fixture after SQLite copies the first batch.
    #[cfg(feature = "backup-test-support")]
    pub fn after_first_batch(&mut self, callback: impl FnOnce() + Send + 'static) {
        self.after_first_batch = Some(Box::new(callback));
    }

    /// Call on the blocking worker. A failed or skipped backup never fails the gateway.
    pub fn perform(&mut self, pressure: impl Fn() -> BackupPressure + Send + Sync + 'static) {
        if self.status.cancelled() {
            return;
        }
        let status = self.status.clone();
        let pressure_sample = Arc::new(Mutex::new((None, BackupPressure::Normal)));
        let mut check = SnapshotCheck::online({
            let pressure_sample = pressure_sample.clone();
            move || {
                if status.cancelled() {
                    return Err(Error::Storage);
                }
                let mut sample = pressure_sample.lock().expect("backup pressure");
                // A SQLite progress callback and each hash chunk can check frequently.
                if sample.1 == BackupPressure::Normal
                    && sample
                        .0
                        .is_none_or(|last: Instant| last.elapsed() >= Duration::from_millis(500))
                {
                    *sample = (Some(Instant::now()), pressure());
                }
                if sample.1 == BackupPressure::Normal {
                    Ok(())
                } else {
                    Err(Error::Storage)
                }
            }
        });
        #[cfg(feature = "backup-test-support")]
        {
            check.after_first_batch = self.after_first_batch.take();
        }
        let mut phase = BackupFailure::DirectoryUnavailable;
        if let Err(error) = self.perform_checked(&mut check, &mut phase) {
            let skipped = pressure_sample.lock().expect("backup pressure").1;
            if self.status.cancelled() {
                self.status.failure(BackupFailure::Cancelled);
            } else if skipped != BackupPressure::Normal {
                self.status.update(|status| {
                    status.last_skipped_unix_seconds = now().ok();
                    status.skipped_pressure = Some(skipped);
                });
            } else {
                self.status.failure(match error {
                    Error::Database(DatabaseError::StoragePressure) => {
                        BackupFailure::InsufficientSpace
                    }
                    _ => phase,
                });
            }
            if !self.status.cancelled() {
                let _ = self.refresh_inventory();
            }
        }
    }

    fn perform_checked(&self, check: &mut SnapshotCheck, phase: &mut BackupFailure) -> Result<()> {
        check.run()?;
        validate_root(&self.root)?;
        let (mut count, owned) = self.owned_entries()?;
        directory_bytes(&self.root, &self.status)?;
        for item in owned {
            if item.partial {
                check.run()?;
                files::private_directory(&item.path)?;
                fs::remove_dir_all(item.path)?;
                count -= 1;
            }
        }
        if count >= MAX_ROOT_ENTRIES {
            return Err(Error::Capacity);
        }

        *phase = BackupFailure::SnapshotFailed;
        let path = self.source.path();
        let source = snapshot::open_snapshot(path)?;
        let micros = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| Error::Invalid)?
            .as_micros();
        let name = format!("online-{micros}-{}", new_id(&source)?);
        let partial = self.root.join(format!("{name}.partial"));
        snapshot::backup_checked(&source, path, &partial, self.protection.as_deref(), check)?;
        drop(source);

        *phase = BackupFailure::VerificationFailed;
        check.run()?;
        let manifest =
            snapshot::verify_backup_checked(&partial, self.protection.as_deref(), check)?;
        check.run()?;
        fs::rename(&partial, self.root.join(name))?;
        files::sync_directory(&self.root)?;
        self.status.update(|status| {
            status.last_success_unix_seconds = Some(manifest.created_unix_seconds)
        });

        *phase = BackupFailure::RetentionFailed;
        let inventory = self.inventory()?;
        let excess = inventory.len().saturating_sub(RETAINED_BUNDLES);
        for entry in inventory.into_iter().take(excess) {
            check.run()?;
            // Keep a bundle intact at its completed name until it is retired. An interruption
            // during removal leaves a partial directory that the next round can clean up.
            let _lock = files::lock(&entry.path.join("snapshot.sqlite.lock"), false)?;
            let retired = files::sidecar(&entry.path, ".partial");
            fs::rename(&entry.path, &retired)?;
            files::sync_directory(&self.root)?;
            fs::remove_dir_all(retired)?;
        }
        files::sync_directory(&self.root)?;
        self.refresh_inventory()
    }

    fn owned_entries(&self) -> Result<(usize, Vec<OwnedEntry>)> {
        let mut count = 0;
        let mut owned = Vec::new();
        for (index, entry) in self.root.read_dir()?.enumerate() {
            if index >= MAX_ROOT_ENTRIES {
                return Err(Error::Capacity);
            }
            count += 1;
            if let Some(entry) = OwnedEntry::from_directory_entry(entry?) {
                owned.push(entry);
            }
        }
        Ok((count, owned))
    }

    fn inventory(&self) -> Result<Vec<Entry>> {
        validate_root(&self.root)?;
        let mut entries = Vec::new();
        let (_, owned) = self.owned_entries()?;
        for entry in owned.into_iter().filter(|entry| !entry.partial) {
            files::private_directory(&entry.path)?;
            let bytes = files::read_bounded(&entry.path.join("manifest.json"), 8192)?;
            let manifest: SnapshotManifest = serde_json::from_slice(&bytes)?;
            if manifest.format != 1
                || !is_uuid(&manifest.id)
                || manifest.created_unix_seconds <= 0
                || !(1..=MAX_DATABASE_BYTES).contains(&manifest.database_bytes)
            {
                return Err(Error::Invalid);
            }
            entries.push(Entry {
                path: entry.path,
                created: manifest.created_unix_seconds,
                bytes: manifest.database_bytes as u64 + bytes.len() as u64,
            });
        }
        entries.sort_unstable_by(|a, b| (a.created, &a.path).cmp(&(b.created, &b.path)));
        Ok(entries)
    }

    fn refresh_inventory(&self) -> Result<()> {
        let entries = self.inventory()?;
        let total_bytes = directory_bytes(&self.root, &self.status)?;
        self.status.update(|status| {
            status.retained_count = entries.len();
            status.total_bytes = total_bytes;
            status.last_success_unix_seconds = entries.last().map(|entry| entry.created);
            status.largest_bundle_bytes =
                entries.iter().map(|entry| entry.bytes).max().unwrap_or(0);
        });
        Ok(())
    }
}

struct Entry {
    path: PathBuf,
    created: i64,
    bytes: u64,
}

struct OwnedEntry {
    path: PathBuf,
    partial: bool,
}

impl OwnedEntry {
    fn from_directory_entry(entry: DirEntry) -> Option<Self> {
        let name = entry.file_name();
        let name = name.to_str()?.strip_prefix("online-")?;
        let base = name.strip_suffix(".partial");
        let body = base.unwrap_or(name);
        let (time, id) = body.split_once('-')?;
        (!time.is_empty() && time.bytes().all(|byte| byte.is_ascii_digit()) && is_uuid(id)).then(
            || Self {
                path: entry.path(),
                partial: base.is_some(),
            },
        )
    }
}

fn validate_root(path: &Path) -> Result<()> {
    files::private_directory(path)?;
    if !path.is_absolute() || path.symlink_metadata()?.mode() & 0o700 != 0o700 {
        return Err(Error::Invalid);
    }
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::Invalid)?;
    // SAFETY: the NUL-terminated path is live for this call.
    if unsafe { libc::access(path.as_ptr(), libc::W_OK | libc::X_OK) } == 0 {
        Ok(())
    } else {
        Err(Error::Storage)
    }
}

fn directory_bytes(root: &Path, status: &BackupStatus) -> Result<u64> {
    let mut directories = vec![root.to_owned()];
    let mut count = 0;
    let mut bytes = 0_u64;
    while let Some(directory) = directories.pop() {
        if status.cancelled() {
            return Err(Error::Storage);
        }
        for entry in directory.read_dir()? {
            if status.cancelled() {
                return Err(Error::Storage);
            }
            count += 1;
            if count > MAX_SCAN_ENTRIES {
                return Err(Error::Capacity);
            }
            let entry = entry?;
            let metadata = entry.metadata()?;
            if metadata.is_symlink() {
                return Err(Error::Invalid);
            }
            if metadata.is_dir() {
                directories.push(entry.path());
            } else if metadata.is_file() {
                bytes = bytes.checked_add(metadata.len()).ok_or(Error::Capacity)?;
            }
        }
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use codexone_storage::Database;

    use super::*;

    fn normal() -> BackupPressure {
        BackupPressure::Normal
    }

    #[test]
    fn interrupted_retention_keeps_published_bundles_and_resumes_next_round() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let database = Database::open_or_create(root.join("core.sqlite")).unwrap();
        let directory = root.join("backups");
        files::create_directory(&directory).unwrap();
        let manual = directory.join("manual-bundle");
        snapshot::backup_locked(database.connection(), database.path(), &manual, None).unwrap();

        let mut job = OnlineBackup::new(directory.clone(), database.backup_source(), None);
        for _ in 0..RETAINED_BUNDLES {
            job.perform(normal);
        }
        let before = job.inventory().unwrap();
        assert_eq!(before.len(), RETAINED_BUNDLES);
        let oldest = &before[0].path;

        // An in-progress verify/restore holds the same lock. The replacement can publish,
        // but the old bundle stays complete when retirement fails.
        let inspecting = files::lock(&oldest.join("snapshot.sqlite.lock"), false).unwrap();
        job.perform(normal);
        let status = job.status();
        assert_eq!(
            status.observation().last_failure,
            Some(BackupFailure::RetentionFailed)
        );
        assert_eq!(status.observation().retained_count, RETAINED_BUNDLES + 1);
        assert!(oldest.is_dir());
        drop(inspecting);

        // Reproduce interruption once the completed name has been durably retired.
        let partial = files::sidecar(oldest, ".partial");
        fs::rename(oldest, &partial).unwrap();
        files::sync_directory(&directory).unwrap();
        drop(job);
        let mut job = OnlineBackup::new(directory, database.backup_source(), None);
        assert_eq!(job.status().observation().retained_count, RETAINED_BUNDLES);
        assert!(
            job.status()
                .observation()
                .last_success_unix_seconds
                .is_some()
        );
        job.perform(|| BackupPressure::Degraded);
        let observation = job.status().observation();
        assert_eq!(observation.skipped_pressure, Some(BackupPressure::Degraded));
        assert!(observation.last_skipped_unix_seconds.is_some());
        let document = serde_json::to_value(observation).unwrap();
        assert_eq!(document["enabled"], true);
        assert_eq!(document["retainedCount"], RETAINED_BUNDLES);
        assert_eq!(document["skippedPressure"], "degraded");
        assert!(document.get("lastFailure").is_none());
        assert!(partial.is_dir());

        job.perform(normal);
        assert!(!partial.exists());
        let retained = job.inventory().unwrap();
        assert_eq!(retained.len(), RETAINED_BUNDLES);
        for entry in retained {
            snapshot::verify_backup(&entry.path, None).unwrap();
        }
        snapshot::verify_backup(&manual, None).unwrap();
    }

    #[test]
    fn interrupted_copy_keeps_the_previous_completed_bundle() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let database_path = root.join("core.sqlite");
        let database = Database::open_or_create(&database_path).unwrap();
        let directory = root.join("backups");
        files::create_directory(&directory).unwrap();
        let mut job = OnlineBackup::new(directory, database.backup_source(), None);
        job.perform(normal);
        let original = job.inventory().unwrap().pop().unwrap().path;
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let mut check = SnapshotCheck::online(move || {
            if calls.fetch_add(1, Ordering::Relaxed) >= 2 {
                Err(Error::Storage)
            } else {
                Ok(())
            }
        });
        let mut failure = BackupFailure::DirectoryUnavailable;
        assert!(job.perform_checked(&mut check, &mut failure).is_err());
        assert_eq!(failure, BackupFailure::SnapshotFailed);
        assert!(
            job.owned_entries()
                .unwrap()
                .1
                .iter()
                .any(|entry| entry.partial)
        );
        assert_eq!(job.inventory().unwrap().len(), 1);
        snapshot::verify_backup(&original, None).unwrap();

        drop(database);
        assert_eq!(
            Database::open_existing(&database_path).err(),
            Some(DatabaseError::InstanceLocked)
        );
        drop(job);
        Database::open_existing(&database_path).unwrap();
    }
}
