use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

pub(crate) fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

pub(crate) fn private_data(path: &Path, maximum: usize) -> io::Result<Zeroizing<Vec<u8>>> {
    let mut file = open_regular(path, false, false)?;
    let info = file.metadata()?;
    if info.mode() & 0o077 != 0 || info.size() == 0 || info.size() > maximum as u64 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut data = Zeroizing::new(Vec::with_capacity(maximum + 1));
    Read::by_ref(&mut file)
        .take(maximum as u64 + 1)
        .read_to_end(&mut data)?;
    if data.is_empty() || data.len() > maximum {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(data)
}

pub(crate) fn database_file(path: &Path, create: bool) -> io::Result<File> {
    let file = open_regular(path, true, create)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(file)
}

pub(crate) fn lock_exclusive(file: &File) -> io::Result<()> {
    // SAFETY: the open file descriptor remains valid for this call.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn open_regular(path: &Path, write: bool, create: bool) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(write)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let info = file.metadata()?;
    // SAFETY: geteuid has no arguments or memory preconditions.
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.nlink() != 1 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(file)
}
