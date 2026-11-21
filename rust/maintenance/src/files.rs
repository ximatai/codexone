use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use codexone_storage::DatabaseError;
use sha2::{Digest, Sha256};

use crate::{Error, MAX_DATABASE_BYTES, Result};

pub(crate) fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

pub(crate) fn parent(path: &Path) -> Result<&Path> {
    path.parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(Error::Invalid)
}

fn uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

pub(crate) fn private_directory(path: &Path) -> Result<()> {
    let meta = path.symlink_metadata()?;
    if !meta.is_dir() || meta.uid() != uid() || meta.mode() & 0o077 != 0 {
        return Err(Error::Invalid);
    }
    Ok(())
}

pub(crate) fn create_directory(path: &Path) -> io::Result<()> {
    DirBuilder::new().mode(0o700).create(path)
}

pub(crate) fn new_file(path: &Path) -> Result<File> {
    Ok(OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?)
}

fn open_private(path: &Path, create: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(create)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.uid() != uid() || meta.nlink() != 1 || meta.mode() & 0o077 != 0 {
        return Err(Error::Invalid);
    }
    Ok(file)
}

pub(crate) fn lock(path: &Path, create: bool) -> Result<File> {
    let file = open_private(path, create)?;
    // SAFETY: the file descriptor remains open for the lifetime of the returned guard.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = io::Error::last_os_error();
        return if error.kind() == io::ErrorKind::WouldBlock {
            Err(DatabaseError::InstanceLocked.into())
        } else {
            Err(error.into())
        };
    }
    Ok(file)
}

pub(crate) fn read_bounded(path: &Path, maximum: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    open_private(path, false)?
        .take(maximum as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > maximum {
        return Err(Error::Capacity);
    }
    Ok(bytes)
}

pub(crate) fn write_synced(path: &Path, data: &[u8]) -> Result<()> {
    let mut file = new_file(path)?;
    file.write_all(data)?;
    file.sync_all()?;
    Ok(())
}

pub(crate) fn sync_directory(path: &Path) -> Result<()> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(path)?
        .sync_all()?;
    Ok(())
}

pub(crate) fn sync_file(path: &Path) -> Result<()> {
    open_private(path, false)?.sync_all()?;
    Ok(())
}

pub(crate) fn fingerprint(path: &Path) -> Result<(i64, String)> {
    let mut input = open_private(path, false)?;
    let mut bytes = 0;
    let mut digest = Sha256::new();
    let mut chunk = [0; 65_536];
    loop {
        let count = input.read(&mut chunk)?;
        if count == 0 {
            break;
        }
        bytes += count as i64;
        if bytes > MAX_DATABASE_BYTES {
            return Err(Error::Capacity);
        }
        digest.update(&chunk[..count]);
    }
    Ok((bytes, hex::encode(digest.finalize())))
}

pub(crate) fn require_absent(path: &Path, suffixes: &[&str]) -> Result<()> {
    for suffix in suffixes {
        match fs::symlink_metadata(sidecar(path, suffix)) {
            Ok(_) => return Err(Error::Invalid),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
