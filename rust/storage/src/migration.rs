use std::ffi::CString;
use std::fs::File;
use std::mem::MaybeUninit;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::Duration;

use rusqlite::Connection;
use rusqlite::backup::{Backup, StepResult};
use tempfile::Builder;

use crate::database::{DatabaseError, WRITER_FLAGS, pragma_integer};
use crate::files::sidecar;

const MIB: i64 = 1024 * 1024;
const OPTIONAL_HEADROOM: i64 = 256 * MIB;
const MAX_ADDITIONAL_BYTES: i64 = 1024 * 1024 * MIB;

pub(crate) fn require_capacity(
    directory: &Path,
    connection: &Connection,
    copies: i64,
    extra_mib: i64,
) -> Result<(), DatabaseError> {
    let pages = pragma_integer(connection, "page_count")?;
    let page_size = pragma_integer(connection, "page_size")?;
    let additional = pages
        .checked_mul(page_size)
        .and_then(|size| size.checked_mul(copies))
        .and_then(|size| size.checked_add(extra_mib * MIB))
        .ok_or(DatabaseError::StoragePressure)?;
    require_free_space(directory, additional, true)
}

/// Check user-available capacity against the Swift storage pressure thresholds.
pub fn require_free_space(
    directory: &Path,
    additional: i64,
    optional: bool,
) -> Result<(), DatabaseError> {
    use DatabaseError::StoragePressure;

    let path = CString::new(directory.as_os_str().as_bytes()).map_err(|_| StoragePressure)?;
    let mut volume = MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: path is NUL terminated and volume points to writable statvfs storage.
    if unsafe { libc::statvfs(path.as_ptr(), volume.as_mut_ptr()) } != 0 {
        return Err(StoragePressure);
    }
    // SAFETY: statvfs initialized volume on success.
    let volume = unsafe { volume.assume_init() };
    let available = u128::from(volume.f_bavail) * u128::from(volume.f_frsize);
    let headroom = if optional {
        OPTIONAL_HEADROOM
    } else {
        128 * MIB
    };
    if !(0..=MAX_ADDITIONAL_BYTES).contains(&additional)
        || available < (headroom + additional) as u128
        || available > i64::MAX as u128
    {
        return Err(StoragePressure);
    }
    Ok(())
}

pub(crate) fn backup_before_upgrade(
    path: &Path,
    directory: &Path,
    source: &Connection,
    version: i64,
) -> Result<(), DatabaseError> {
    use DatabaseError::StorageUnavailable;

    require_capacity(directory, source, 1, 8)?;
    let id: String = source.query_row(
        "SELECT hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' ||
            substr(hex(randomblob(2)),2) || '-8' || substr(hex(randomblob(2)),2) ||
            '-' || hex(randomblob(6))",
        [],
        |row| row.get(0),
    )?;
    let destination = sidecar(
        path,
        &format!(".pre-v{}-{id}.sqlite", (version + 1).max(13)),
    );
    let partial = Builder::new()
        .prefix(destination.file_name().ok_or(StorageUnavailable)?)
        .rand_bytes(0) // The prefix already contains the random backup ID.
        .suffix(".partial")
        .tempfile_in(directory)
        .map_err(|_| StorageUnavailable)?;
    let mut target = Connection::open_with_flags(partial.path(), WRITER_FLAGS)?;
    target.busy_timeout(Duration::ZERO)?;
    target.pragma_update(None, "synchronous", "FULL")?;
    {
        let copy = Backup::new(source, &mut target)?;
        loop {
            require_free_space(directory, 2 * MIB, true)?;
            match copy.step(128)? {
                StepResult::Done => break,
                StepResult::More => {}
                _ => return Err(StorageUnavailable),
            }
        }
    }
    let journal: String = target.query_row("PRAGMA journal_mode=DELETE", [], |row| row.get(0))?;
    if journal != "delete" {
        return Err(StorageUnavailable);
    }
    target.close().map_err(|_| StorageUnavailable)?;
    partial
        .as_file()
        .sync_all()
        .map_err(|_| StorageUnavailable)?;
    partial
        .persist_noclobber(destination)
        .map_err(|_| StorageUnavailable)?;
    File::open(directory)
        .and_then(|parent| parent.sync_all())
        .map_err(|_| StorageUnavailable)?;
    Ok(())
}
