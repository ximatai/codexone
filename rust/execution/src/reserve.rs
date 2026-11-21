use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::{
    ffi::OsStrExt,
    fs::{FileExt, MetadataExt, OpenOptionsExt},
};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, ErrorCode, wal::CheckpointMode};

use crate::{ExecutionError as Error, Result};

const MIB: u64 = 1024 * 1024;
const RESERVE_BYTES: u64 = 64 * MIB;
const STOP_BYTES: u64 = 128 * MIB;
const RESUME_BYTES: u64 = 192 * MIB;
const MAGIC: &[u8] = b"CodexOneSettlementReserveV1\n";

pub(crate) struct StorageReserve {
    file: File,
    directory: PathBuf,
    wal: PathBuf,
    blocked: bool,
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
            file,
            directory,
            wal: sidecar(path, "-wal"),
            blocked: true,
        };
        let size = result.size()?;
        let prefix_len = MAGIC.len().min(size as usize);
        let mut prefix = [0; MAGIC.len()];
        result
            .file
            .read_exact_at(&mut prefix[..prefix_len], 0)
            .map_err(|_| Error::StorageUnavailable)?;
        if prefix[..prefix_len] != MAGIC[..prefix_len] {
            return Err(Error::StorageUnavailable);
        }
        File::open(&result.directory)
            .and_then(|dir| dir.sync_all())
            .map_err(|_| Error::StorageUnavailable)?;
        Ok(result)
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
        let start = self.size()?;
        if start == RESERVE_BYTES
            || available(&self.directory)
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
            if let Err(error) = self.file.write_all_at(&zeros[..size], cursor) {
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
        self.file
            .sync_all()
            .map_err(|_| Error::StorageUnavailable)?;
        self.size()?;
        Ok(())
    }

    fn wal_size(&self) -> Result<u64> {
        match fs::symlink_metadata(&self.wal) {
            Ok(stat) if stat.is_file() => Ok(stat.len()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
            _ => Err(Error::StorageUnavailable),
        }
    }

    pub(crate) fn check_optional(&mut self) -> Result<()> {
        self.check_admission()?;
        if available(&self.directory).is_none_or(|bytes| bytes < 256 * MIB)
            || self.wal_size()? >= 64 * MIB
        {
            return Err(Error::StoragePressure);
        }
        Ok(())
    }

    pub(crate) fn check_admission(&mut self) -> Result<()> {
        let wal = self.wal_size()?;
        let size = self.size()?;
        let enough = available(&self.directory).is_some_and(|bytes| {
            bytes
                >= if self.blocked {
                    RESUME_BYTES
                } else {
                    STOP_BYTES
                }
        });
        self.blocked = !enough
            || size != RESERVE_BYTES
            || wal >= 128 * MIB
            || (self.blocked && wal > 32 * MIB);
        if self.blocked {
            Err(Error::StoragePressure)
        } else {
            Ok(())
        }
    }

    pub(crate) fn prepare_critical(&mut self) -> Result<()> {
        let size = self.size()?;
        if size > 0 && available(&self.directory).is_none_or(|bytes| bytes < STOP_BYTES) {
            self.file
                .set_len(size.saturating_sub(8 * MIB))
                .and_then(|()| self.file.sync_all())
                .map_err(|_| Error::StorageUnavailable)?;
            self.blocked = true;
        }
        Ok(())
    }
}

fn ignore_checkpoint_busy(checkpoint: rusqlite::Result<(i32, i32)>) -> Result<()> {
    match checkpoint {
        Ok(_) => Ok(()),
        Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseBusy) => Ok(()),
        Err(error) => Err(error.into()),
    }
}
