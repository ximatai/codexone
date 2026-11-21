//! Bounded account-owned quota jobs and management commands over the gateway writer.

mod priming;
mod reset;
mod reset_store;
mod reset_types;
mod settings;

pub use codexone_identity_runtime::priming::PrimingSettings;
pub use priming::{
    PrimingModel, PrimingRequest, PrimingSignals, PrimingStatus, PrimingSupervisor,
    PrimingTransport, PrimingWorker,
};
pub use reset::ResetSupervisor;
pub use reset_types::{
    ResetCode, ResetCredit, ResetList, ResetListing, ResetResult, ResetSettings, ResetStatus,
};
pub use settings::{PrimingSettingsUpdate, ResetConsume, ResetSettingsUpdate};

fn valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}
