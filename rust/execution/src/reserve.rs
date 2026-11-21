use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::{
    ffi::OsStrExt,
    fs::{FileExt, MetadataExt, OpenOptionsExt},
};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use rusqlite::{Connection, ErrorCode, wal::CheckpointMode};

use crate::{ExecutionError as Error, Result};

const MIB: u64 = 1024 * 1024;
const RESERVE_BYTES: u64 = 64 * MIB;
const STOP_BYTES: u64 = 128 * MIB;
const RESUME_BYTES: u64 = 192 * MIB;
const MAGIC: &[u8] = b"CodexOneSettlementReserveV1\n";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StoragePressure {
    Normal,
    Degraded,
    Blocked,
    Unknown,
}

pub(crate) struct StorageReserve {
    monitor: StorageMonitor,
}

#[derive(Clone)]
pub(crate) struct StorageMonitor(Arc<ReserveFiles>);

struct ReserveFiles {
    file: File,
    directory: PathBuf,
    wal: PathBuf,
    blocked: AtomicBool,
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut joined = path.as_os_str().to_owned();
    joined.push(suffix);
    joined.into()
}

fn available(directory: &Path) -> Option<u64> {
    let directory = CString::new(directory.as_os_str().as_bytes()).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // statvfs initializes the record on success. The C path lives through the call.
    if unsafe { libc::statvfs(directory.as_ptr(), info.as_mut_ptr()) } != 0 {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let bytes = u128::from(info.f_bavail) * u128::from(info.f_frsize);
    (info.f_frsize > 0)
        .then(|| u64::try_from(bytes).ok())
        .flatten()
}

impl StorageReserve {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        let directory = path.parent().ok_or(Error::StorageUnavailable)?.to_owned();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(sidecar(path, ".settlement-reserve"))
            .map_err(|_| Error::StorageUnavailable)?;
        let result = Self {
            monitor: StorageMonitor(Arc::new(ReserveFiles {
                file,
                directory,
                wal: sidecar(path, "-wal"),
                blocked: AtomicBool::new(true),
            })),
        };
        let files = &result.monitor.0;
        let size = files.size()?;
        let prefix_len = MAGIC.len().min(size as usize);
        let mut prefix = [0; MAGIC.len()];
        files
            .file
            .read_exact_at(&mut prefix[..prefix_len], 0)
            .map_err(|_| Error::StorageUnavailable)?;
        if prefix[..prefix_len] != MAGIC[..prefix_len] {
            return Err(Error::StorageUnavailable);
        }
        File::open(&files.directory)
            .and_then(|dir| dir.sync_all())
            .map_err(|_| Error::StorageUnavailable)?;
        Ok(result)
    }

    pub(crate) fn monitor(&self) -> StorageMonitor {
        self.monitor.clone()
    }

    pub(crate) fn maintain(&mut self, db: &Connection) -> Result<()> {
        // Passive checkpoint keeps busy readers outside the critical settlement path.
        match db.wal_checkpoint_v2(Some("main"), CheckpointMode::PASSIVE) {
            Ok((frames, checkpointed)) if frames > 0 && frames == checkpointed => {
                db.busy_timeout(std::time::Duration::ZERO)?;
                let checkpoint = db.wal_checkpoint_v2(Some("main"), CheckpointMode::TRUNCATE);
                db.busy_timeout(std::time::Duration::from_millis(250))?;
                ignore_checkpoint_busy(checkpoint)?;
            }
            checkpoint => ignore_checkpoint_busy(checkpoint)?,
        }
        let files = &self.monitor.0;
        let start = files.size()?;
        if start == RESERVE_BYTES
            || available(&files.directory)
                .is_none_or(|bytes| bytes < RESUME_BYTES + RESERVE_BYTES - start)
        {
            return Ok(());
        }
        let mut zeros = vec![0; MIB as usize];
        let mut cursor = start;
        while cursor < RESERVE_BYTES {
            let size = (RESERVE_BYTES - cursor).min(MIB) as usize;
            let prefix = MAGIC.get(cursor as usize..).unwrap_or_default();
            zeros[..prefix.len()].copy_from_slice(prefix);
            if let Err(error) = files.file.write_all_at(&zeros[..size], cursor) {
                // A racing writer may consume the free space after our sample. Retain the
                // allocated prefix so already durable intents can still release it.
                if error.raw_os_error() == Some(libc::ENOSPC) {
                    break;
                }
                return Err(Error::StorageUnavailable);
            }
            zeros[..prefix.len()].fill(0);
            cursor += size as u64;
        }
        files
            .file
            .sync_all()
            .map_err(|_| Error::StorageUnavailable)?;
        files.size()?;
        Ok(())
    }

    pub(crate) fn check_optional(&mut self) -> Result<()> {
        self.check_admission()?;
        let files = &self.monitor.0;
        if available(&files.directory).is_none_or(|bytes| bytes < 256 * MIB)
            || files.wal_size()? >= 64 * MIB
        {
            return Err(Error::StoragePressure);
        }
        Ok(())
    }

    pub(crate) fn check_admission(&mut self) -> Result<()> {
        let files = &self.monitor.0;
        let wal = files.wal_size()?;
        let size = files.size()?;
        let available = available(&files.directory);
        let blocked = available.is_none_or(|available| files.blocks(available, wal, size));
        files.blocked.store(blocked, Ordering::Relaxed);
        if blocked {
            Err(Error::StoragePressure)
        } else {
            Ok(())
        }
    }

    pub(crate) fn prepare_critical(&mut self) -> Result<()> {
        let files = &self.monitor.0;
        let size = files.size()?;
        if size > 0 && available(&files.directory).is_none_or(|bytes| bytes < STOP_BYTES) {
            files
                .file
                .set_len(size.saturating_sub(8 * MIB))
                .and_then(|()| files.file.sync_all())
                .map_err(|_| Error::StorageUnavailable)?;
            files.blocked.store(true, Ordering::Relaxed);
        }
        Ok(())
    }
}

impl StorageMonitor {
    /// Samples the writer's reserve without changing admission hysteresis or queueing a job.
    pub(crate) fn pressure(&self) -> StoragePressure {
        let files = &self.0;
        let (Some(available), Ok(wal), Ok(size)) =
            (available(&files.directory), files.wal_size(), files.size())
        else {
            return StoragePressure::Unknown;
        };
        if files.blocks(available, wal, size) {
            StoragePressure::Blocked
        } else if available < 256 * MIB || wal >= 64 * MIB {
            StoragePressure::Degraded
        } else {
            StoragePressure::Normal
        }
    }
}

impl ReserveFiles {
    fn blocks(&self, available: u64, wal: u64, size: u64) -> bool {
        let blocked = self.blocked.load(Ordering::Relaxed);
        available < if blocked { RESUME_BYTES } else { STOP_BYTES }
            || size != RESERVE_BYTES
            || wal >= 128 * MIB
            || (blocked && wal > 32 * MIB)
    }

    fn size(&self) -> Result<u64> {
        let meta = self
            .file
            .metadata()
            .map_err(|_| Error::StorageUnavailable)?;
        if !meta.is_file()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.nlink() != 1
            || meta.mode() & 0o077 != 0
            || meta.len() > RESERVE_BYTES
            || meta.blocks().saturating_mul(512) < meta.len()
        {
            return Err(Error::StorageUnavailable);
        }
        Ok(meta.len())
    }

    fn wal_size(&self) -> Result<u64> {
        match fs::symlink_metadata(&self.wal) {
            Ok(stat) if stat.is_file() => Ok(stat.len()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
            _ => Err(Error::StorageUnavailable),
        }
    }
}

fn ignore_checkpoint_busy(checkpoint: rusqlite::Result<(i32, i32)>) -> Result<()> {
    match checkpoint {
        Ok(_) => Ok(()),
        Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseBusy) => Ok(()),
        Err(error) => Err(error.into()),
    }
}
