//! Durable execution for the Swift-compatible v19 ledger.

mod admission;
mod ledger;
mod model;
mod priming;
mod reserve;
pub use reserve::{
    STORAGE_STOP_BYTES, STORAGE_WAL_STOP_BYTES, StorageObservation, StoragePressure,
};
mod static_identity;
mod worker;

pub use codexone_account_pool::{
    Identity as AccountIdentity, SessionAffinity, SessionLabel, TurnStateOwners,
};
pub use model::*;
pub use static_identity::{
    FixedIdentity, StaticAdmissionRequest, StaticAuthorization, StaticIdentity,
    StaticIdentityConfig,
};
pub use worker::{
    AccountConnection, Execution, ExecutionService, ExecutionStatus, GovernanceWork, Options,
};

use std::{error::Error, fmt};

pub type Result<T> = std::result::Result<T, ExecutionError>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionError {
    InvalidCommand,
    Unauthorized,
    KeyExpired,
    AccountUnavailable,
    AccountForceStopped,
    AccountConcurrency,
    AccountCooldown { retry_after_seconds: u64 },
    ContinuationOwnerUnavailable,
    KeyLimit,
    UnknownObject,
    AmbiguousObject,
    UnknownAttempt,
    Conflict,
    StaleEvidence,
    Capacity,
    StoragePressure,
    StorageUnavailable,
    MaintenanceRequired,
    DeadlineExceeded,
    Database(codexone_storage::DatabaseError),
    Closed,
}

impl fmt::Display for ExecutionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => error.fmt(f),
            other => write!(f, "{other:?}"),
        }
    }
}

impl Error for ExecutionError {}

impl From<rusqlite::Error> for ExecutionError {
    fn from(_: rusqlite::Error) -> Self {
        Self::StorageUnavailable
    }
}

impl From<serde_json::Error> for ExecutionError {
    fn from(_: serde_json::Error) -> Self {
        Self::StorageUnavailable
    }
}

impl From<codexone_storage::DatabaseError> for ExecutionError {
    fn from(error: codexone_storage::DatabaseError) -> Self {
        use codexone_storage::DatabaseError;
        match error {
            DatabaseError::StorageUnavailable => Self::StorageUnavailable,
            other => Self::Database(other),
        }
    }
}

impl From<codexone_account_pool::Error> for ExecutionError {
    fn from(error: codexone_account_pool::Error) -> Self {
        use codexone_account_pool::Error;
        match error {
            Error::InvalidCommand => Self::InvalidCommand,
            Error::StorageUnavailable => Self::StorageUnavailable,
            Error::UnknownObject => Self::UnknownObject,
            Error::AmbiguousObject => Self::AmbiguousObject,
            Error::AccountUnavailable => Self::AccountUnavailable,
            Error::AccountConcurrency => Self::AccountConcurrency,
            Error::Wait(duration) => Self::AccountCooldown {
                retry_after_seconds: duration.as_micros().div_ceil(1_000_000) as u64,
            },
            Error::Cooldown {
                retry_after_seconds,
            } => Self::AccountCooldown {
                retry_after_seconds,
            },
            Error::Capacity => Self::Capacity,
            Error::Closed => Self::Closed,
            Error::ContinuationOwnerUnavailable => Self::ContinuationOwnerUnavailable,
        }
    }
}
