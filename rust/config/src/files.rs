use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use rustix::fd::AsFd;
use rustix::fs::{self, Access, Dir, FileType, Mode, OFlags, Stat};
use rustix::process::geteuid;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const FILE_FLAGS: OFlags = OFlags::RDONLY
    .union(OFlags::CLOEXEC)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::NONBLOCK);
const DIRECTORY_FLAGS: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::CLOEXEC)
    .union(OFlags::NOFOLLOW);

fn read_checked(
    parent: impl AsFd,
    path: impl rustix::path::Arg,
    maximum: usize,
    private: bool,
) -> Option<Vec<u8>> {
    let descriptor = fs::openat(parent, path, FILE_FLAGS, Mode::empty()).ok()?;
    let info = fs::fstat(&descriptor).ok()?;
    let mode_mask = if private { 0o077 } else { 0o022 };
    if FileType::from_raw_mode(info.st_mode) != FileType::RegularFile
        || !(info.st_uid == geteuid().as_raw() || !private && info.st_uid == 0)
        || info.st_nlink != 1
        || info.st_mode & mode_mask != 0
        || !(1..=maximum as i64).contains(&info.st_size)
    {
        return None;
    }
    let mut data = Vec::with_capacity(info.st_size as usize);
    File::from(descriptor)
        .take(maximum as u64 + 1)
        .read_to_end(&mut data)
        .ok()?;
    (data.len() <= maximum && (private || data.len() == info.st_size as usize)).then_some(data)
}

pub(crate) fn read_private(path: &Path, maximum: usize) -> Option<Vec<u8>> {
    read_checked(fs::CWD, path, maximum, true)
}

// Foundation's whitespacesAndNewlines set also includes zero-width space.
pub(crate) fn trim(value: &str) -> &str {
    value.trim_matches(|ch: char| ch.is_whitespace() || ch == '\u{200b}')
}

pub(crate) fn runtime_secret(path: &Path) -> Option<Zeroizing<String>> {
    let data = read_private(path, 16_384)?;
    let raw = Zeroizing::new(String::from_utf8(data).ok()?);
    let value = trim(&raw);
    (!value.is_empty() && value.bytes().all(|byte| (33..127).contains(&byte)))
        .then(|| Zeroizing::new(value.to_owned()))
}

pub(crate) fn load_admin_digest(path: &Path, forbidden: Option<[u8; 32]>) -> Option<[u8; 32]> {
    let secret = runtime_secret(path)?;
    if !(32..=512).contains(&secret.len()) || secret.starts_with("co1_") {
        return None;
    }
    let digest = sha256(secret.as_bytes());
    (Some(digest) != forbidden).then_some(digest)
}

pub(crate) fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// Raw AES key material for the storage adapter. This type intentionally omits `Debug`.
pub struct MasterKeyring {
    pub active: Zeroizing<[u8; 32]>,
    pub decrypt_only: Vec<Zeroizing<[u8; 32]>>,
}

pub(crate) fn load_master_keyring(
    path: &Path,
    admin_path: Option<&Path>,
    forbidden: Option<[u8; 32]>,
) -> Option<MasterKeyring> {
    let raw = Zeroizing::new(String::from_utf8(read_private(path, 8192)?).ok()?);
    let text = trim(&raw);
    let admin = match admin_path {
        Some(path) => Some(runtime_secret(path)?),
        None => None,
    };
    let separated = |value: &str| {
        !admin
            .as_ref()
            .is_some_and(|admin| admin.eq_ignore_ascii_case(value))
            && forbidden.is_none_or(|digest| {
                sha256(value.as_bytes()) != digest
                    && sha256(Zeroizing::new(value.to_ascii_lowercase()).as_bytes()) != digest
                    && sha256(Zeroizing::new(value.to_ascii_uppercase()).as_bytes()) != digest
            })
    };
    let decode = |value: &str| {
        let mut bytes = Zeroizing::new([0u8; 32]);
        if !separated(value) {
            return None;
        }
        hex::decode_to_slice(value, &mut *bytes).ok()?;
        Some(bytes)
    };
    if !separated(text) {
        return None;
    }
    if !text.starts_with('{') {
        return Some(MasterKeyring {
            active: decode(text)?,
            decrypt_only: Vec::new(),
        });
    }
    let normalized = crate::json::without_trailing_commas(&raw);
    let normalized = match normalized {
        std::borrow::Cow::Owned(text) => Zeroizing::new(text),
        std::borrow::Cow::Borrowed(_) => raw,
    };
    let crate::json::FirstFields(fields) = serde_json::from_str(&normalized).ok()?;
    if fields.len() != 3 {
        return None;
    }
    let format: serde_json::Number = serde_json::from_str(fields.get("format")?.get()).ok()?;
    let inactive: Vec<&serde_json::value::RawValue> =
        serde_json::from_str(fields.get("decryptOnly")?.get()).ok()?;
    if crate::source::integer::parse(&format) != Some(1) || inactive.len() > 7 {
        return None;
    }
    let decode_json = |value: &serde_json::value::RawValue| {
        let material = Zeroizing::new(serde_json::from_str::<String>(value.get()).ok()?);
        decode(&material)
    };
    let active = decode_json(fields.get("active")?)?;
    let mut decrypt_only = Vec::with_capacity(inactive.len());
    for value in inactive {
        let key = decode_json(value)?;
        if key == active || decrypt_only.contains(&key) {
            return None;
        }
        decrypt_only.push(key);
    }
    Some(MasterKeyring {
        active,
        decrypt_only,
    })
}

pub(crate) fn validate_backup_directory(path: &Path) -> Option<()> {
    // Avoid letting a trailing slash make stat follow the final component.
    let path = path.components().collect::<PathBuf>();
    let info = fs::statat(fs::CWD, &path, fs::AtFlags::SYMLINK_NOFOLLOW).ok()?;
    if FileType::from_raw_mode(info.st_mode) != FileType::Directory
        || info.st_uid != geteuid().as_raw()
        || info.st_mode & 0o777 != 0o700
    {
        return None;
    }
    fs::access(path, Access::WRITE_OK | Access::EXEC_OK).ok()
}

pub struct AdminWebBundle {
    pub index: Vec<u8>,
    /// Site assets by bare filename, without the /assets/ prefix.
    pub assets: BTreeMap<String, Vec<u8>>,
}

pub(crate) fn load_web_bundle(path: &Path) -> Option<AdminWebBundle> {
    let root = fs::open(path, DIRECTORY_FLAGS, Mode::empty()).ok()?;
    web_directory_attributes(&fs::fstat(&root).ok()?)?;
    let index = read_checked(&root, "index.html", 65_536, false)?;
    let directory = fs::openat(&root, "assets", DIRECTORY_FLAGS, Mode::empty()).ok()?;
    web_directory_attributes(&fs::fstat(&directory).ok()?)?;
    let mut total = index.len();
    let mut assets = BTreeMap::new();
    for entry in Dir::read_from(&directory).ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name().to_str().ok()?;
        if matches!(name, "." | "..") {
            continue;
        }
        if assets.len() >= 32
            || !ascii_identifier(name, 128)
            || !(name.ends_with(".js") || name.ends_with(".css"))
        {
            return None;
        }
        let data = read_checked(&directory, name, 1_048_576, false)?;
        total += data.len();
        if total > 4_194_304 {
            return None;
        }
        assets.insert(name.to_owned(), data);
    }
    (!assets.is_empty()).then_some(AdminWebBundle { index, assets })
}

fn web_directory_attributes(info: &Stat) -> Option<()> {
    (FileType::from_raw_mode(info.st_mode) == FileType::Directory
        && (info.st_uid == 0 || info.st_uid == geteuid().as_raw())
        && info.st_mode & 0o022 == 0)
        .then_some(())
}

pub(crate) fn ascii_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
}

pub(crate) fn unique<'a>(keys: impl IntoIterator<Item = &'a str>) -> bool {
    use unicode_normalization::UnicodeNormalization;
    let mut seen = HashSet::new();
    keys.into_iter()
        .all(|key| seen.insert(key.nfc().collect::<String>()))
}
