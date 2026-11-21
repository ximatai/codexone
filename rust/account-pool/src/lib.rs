//! Managed-account routing on the caller's Swift-compatible SQLite transaction.

mod health;
mod routing;
mod session;
mod waiters;

pub use health::{Health, HealthObservation, HealthOutcome, HealthUpdate};
pub use routing::{Candidate, Selection, admit, resolve_affinity, resolve_hint};
pub use session::{SessionAffinity, SessionLabel, TurnStateOwners};
pub use waiters::PacingWaiters;

use std::{fmt, time::Duration};

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidCommand,
    StorageUnavailable,
    UnknownObject,
    AmbiguousObject,
    AccountUnavailable,
    AccountConcurrency,
    Wait(Duration),
    Cooldown { retry_after_seconds: u64 },
    Capacity,
    Closed,
    ContinuationOwnerUnavailable,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::StorageUnavailable
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct Identity {
    pub id: String,
    pub namespace: String,
}

impl Identity {
    fn valid(&self) -> bool {
        valid_field(&self.id, 64)
            && self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
            && valid_field(&self.namespace, 512)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Reference<'a> {
    pub kind: &'a str,
    pub raw_id: &'a str,
}

impl Reference<'_> {
    fn valid(self) -> bool {
        valid_field(self.kind, 256) && valid_field(self.raw_id, 256)
    }
}

const MAX_TIME: i64 = 1_000_000_000_000;
const MICROS_PER_SECOND: i64 = 1_000_000;
const ACCOUNT_CAPACITY: i64 = 16;
const MAX_ACCOUNTS: usize = 64;
const MAX_PACING_WAIT: Duration = Duration::from_secs(15);

fn valid_field(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && !value.as_bytes().contains(&0)
}

fn unix_seconds(micros: i64) -> Result<i64> {
    let seconds = micros.div_euclid(MICROS_PER_SECOND);
    (1..=MAX_TIME)
        .contains(&seconds)
        .then_some(seconds)
        .ok_or(Error::InvalidCommand)
}
