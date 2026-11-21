//! Durable single-account execution for the Swift-compatible v19 ledger.

mod admission;
mod ledger;
mod model;
mod reserve;
mod worker;

pub use model::*;
pub use worker::{Execution, ExecutionService, ExecutionStatus, Options};

use std::{error::Error, fmt};

pub type Result<T> = std::result::Result<T, ExecutionError>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionError {
    InvalidCommand,
    Unauthorized,
    KeyExpired,
    AccountUnavailable,
    AccountConcurrency,
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
