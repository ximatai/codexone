//! SQLite v19 and credential format compatibility for CodexOne.

mod credential;
mod database;
mod files;
mod key;
mod migration;
mod schema;

pub use credential::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, CredentialError,
};
pub use database::{
    Database, DatabaseBackupSource, DatabaseError, ReencryptionCheckpoint, SCHEMA_VERSION,
    reencryption_checkpoint,
};
pub use key::{InvalidBearer, bearer_digest, key_digest};
pub use migration::require_free_space;
