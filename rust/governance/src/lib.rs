//! Managed accounts and Keys over the application's existing SQLite writer.

mod accounts;
mod authorization;
mod http_api;
mod keys;
mod refresh;

use std::{fmt, future::Future, sync::Arc};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use codexone_storage::{AccountCredentialCipher, Database, DatabaseError};
use unicode_general_category::{GeneralCategory, get_general_category};
use uuid::Builder;
use zeroize::Zeroizing;

pub use accounts::{Account, AccountMode, AuthorizationState, RefreshIntent, recover_refreshes};
pub use authorization::{
    AuthorizationMethod, AuthorizationProvider, Authorizations, DeviceCode, DeviceGrant,
    FailureCode, NoAuthorizationProvider, PollError, ProviderFailure, Started, Status, Target,
    VerifiedAuthorization,
};
pub use http_api::{AccountRuntime, GovernanceApi, KeyOptions, NoAccountRuntime};
pub use keys::{Key, KeyChange, KeyPolicy, Limits};
pub use refresh::{RefreshFailure, RefreshProvider, RefreshService};

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidCommand,
    InvalidAuthorizationCommand,
    Conflict,
    AccountConflict,
    IdentityMismatch,
    Unauthorized,
    UnknownAccount,
    KeyEnabled,
    KeyArchived,
    KeyNotArchived,
    AuthorizationRequired,
    AuthorizationUnavailable,
    AccountStorageUnavailable,
    Unavailable,
    Capacity,
    StoragePressure,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Unavailable
    }
}

impl From<DatabaseError> for Error {
    fn from(_: DatabaseError) -> Self {
        Self::Unavailable
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Work {
    Read,
    Optional,
    /// Requires the essential write path. The command checks whether it actually
    /// restricts access before using this path when optional work is blocked.
    Restrict,
    /// Marking refresh intent requires storage admission and room for its terminal event.
    Admission,
    /// Completes an already durable refresh intent, including after network failure.
    Critical,
}

/// Submit to the runtime's one SQLite writer. Enforce storage reserve and pressure for
/// the indicated work class. Pass the writer's clock and whether optional work is allowed.
/// Accepted commands must commit or roll back even if the caller drops its reply.
pub trait Writer: Send + Sync + 'static {
    fn run<T: Send + 'static>(
        &self,
        work: Work,
        operation: impl FnOnce(&mut Database, i64, bool) -> Result<T> + Send + 'static,
    ) -> impl Future<Output = Result<T>> + Send;
}

pub struct Governance<W> {
    writer: W,
    cipher: Option<Arc<AccountCredentialCipher>>,
}

impl<W: Writer> Governance<W> {
    pub fn new(writer: W, cipher: Option<AccountCredentialCipher>) -> Self {
        Self {
            writer,
            cipher: cipher.map(Arc::new),
        }
    }
}

fn valid_id(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}

fn id(value: &str) -> Result<()> {
    valid_id(value).then_some(()).ok_or(Error::InvalidCommand)
}

fn display_name(value: Option<&str>) -> Result<()> {
    use GeneralCategory::*;
    if let Some(name) = value
        && (!(1..=64).contains(&name.chars().count())
            || name.chars().any(|ch| match get_general_category(ch) {
                Control | Format | LineSeparator | ParagraphSeparator => true,
                // Foundation includes unassigned scalars in these Unicode planes.
                Unassigned => matches!(u32::from(ch) >> 16, 0..=3 | 14),
                _ => false,
            }))
    {
        return Err(Error::InvalidCommand);
    }
    Ok(())
}

fn check_revision(revision: i64) -> Result<()> {
    if (1..=1_000_000).contains(&revision) {
        Ok(())
    } else {
        Err(Error::InvalidCommand)
    }
}

fn nonce() -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new([0; 32]);
    getrandom::fill(&mut *bytes).map_err(|_| Error::Unavailable)?;
    Ok(Zeroizing::new(URL_SAFE_NO_PAD.encode(*bytes)))
}

fn uuid() -> Result<String> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| Error::Unavailable)?;
    Ok(Builder::from_random_bytes(bytes)
        .into_uuid()
        .to_string()
        .to_uppercase())
}
