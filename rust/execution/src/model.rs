use serde::{Deserialize, Serialize};

use crate::{ExecutionError, Result};

pub(crate) const MAX_AMOUNT: i64 = 1_000_000_000_000;
pub(crate) const DAY: i64 = 86_400;
pub(crate) const BINDING_TTL: i64 = 30 * DAY;
pub(crate) const MAX_REFERENCES: usize = 32;

pub(crate) fn valid_string(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && !value.as_bytes().contains(&0)
}

pub(crate) fn valid_id(value: &str) -> bool {
    valid_string(value, 64)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}

pub(crate) fn valid_model(value: &str) -> bool {
    valid_string(value, 128)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-./:_".contains(&b))
}

pub(crate) fn check_time(now: i64) -> Result<i64> {
    (1..=MAX_AMOUNT)
        .contains(&now)
        .then_some(now)
        .ok_or(ExecutionError::InvalidCommand)
}

pub(crate) fn sanitize_metadata(value: String) -> String {
    if valid_string(&value, 32)
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_-".contains(&b))
    {
        value
    } else {
        "other".into()
    }
}

/// A verified Key revision. The raw bearer never enters the worker queue.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedKey {
    pub(crate) id: String,
    pub(crate) principal: String,
    pub(crate) revision: i64,
}

impl AuthenticatedKey {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn principal(&self) -> &str {
        &self.principal
    }
    pub fn revision(&self) -> i64 {
        self.revision
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Owner {
    pub principal: String,
    pub key: String,
    pub namespace: String,
    pub identity: String,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    #[default]
    Generation,
    Warmup,
    Compact,
    Priming,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Route {
    #[default]
    Conversation,
    Images,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Requirements {
    pub route: Route,
    pub vision_input: bool,
    pub image_model: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct ObjectBinding {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(rename = "rawID")]
    pub raw_id: String,
}

impl ObjectBinding {
    pub(crate) fn validate(&self) -> Result<()> {
        if valid_string(&self.kind, 256) && valid_string(&self.raw_id, 256) {
            Ok(())
        } else {
            Err(ExecutionError::InvalidCommand)
        }
    }
}

/// Captured from the credential selected and verified by the provider adapter.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountDispatchSnapshot {
    pub revision: i64,
    pub credential_version: i64,
    pub access_expires_at_unix_seconds: i64,
    /// True only when the transport has already established connection affinity.
    pub continuation: bool,
}

/// Proof of which stored account supplied the credential metadata used at admission.
#[derive(Clone, Debug)]
pub struct AccountDispatch {
    pub(crate) id: String,
    pub(crate) namespace: String,
    pub(crate) snapshot: AccountDispatchSnapshot,
}

/// Encrypted material for the configured account. Decrypt through codexone-storage.
pub struct AccountCredentialRecord {
    pub(crate) id: String,
    pub(crate) namespace: String,
    pub(crate) revision: i64,
    pub(crate) credential_version: i64,
    pub(crate) envelope: String,
}

impl AccountCredentialRecord {
    pub fn sealed_credential(&self) -> &str {
        &self.envelope
    }

    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn namespace(&self) -> &str {
        &self.namespace
    }
    pub fn credential_version(&self) -> i64 {
        self.credential_version
    }

    pub fn dispatch_snapshot(&self, expires_at: i64, continuation: bool) -> AccountDispatch {
        AccountDispatch {
            id: self.id.clone(),
            namespace: self.namespace.clone(),
            snapshot: AccountDispatchSnapshot {
                revision: self.revision,
                credential_version: self.credential_version,
                access_expires_at_unix_seconds: expires_at,
                continuation,
            },
        }
    }
}

/// Trusted transport classification and selected account snapshot, prepared before admission.
#[derive(Clone, Debug)]
pub struct AdmissionRequest {
    pub attempt: String,
    pub request_id: Option<String>,
    pub key: AuthenticatedKey,
    pub account: AccountDispatch,
    pub model: String,
    pub mode: Mode,
    pub requirements: Requirements,
    pub references: Vec<ObjectBinding>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub policy_version: String,
    pub pricing_version: String,
    pub reserved_micros: i64,
}

impl AdmissionRequest {
    pub(crate) fn validate(&self) -> Result<()> {
        let account = &self.account.snapshot;
        validate_operation(
            &self.attempt,
            self.request_id.as_deref(),
            &self.model,
            self.mode,
            &self.requirements,
            &self.references,
            [
                self.reasoning_effort.as_deref(),
                self.service_tier.as_deref(),
            ],
        )?;
        if !valid_model(&self.model)
            || self
                .requirements
                .image_model
                .as_deref()
                .is_some_and(|model| !valid_model(model))
            || !valid_string(&self.policy_version, 128)
            || !valid_string(&self.pricing_version, 128)
            || !(0..=MAX_AMOUNT).contains(&self.reserved_micros)
            || !(1..=1_000_000).contains(&account.revision)
            || !(1..=1_000_000).contains(&account.credential_version)
            || !(1..=MAX_AMOUNT).contains(&account.access_expires_at_unix_seconds)
        {
            return Err(ExecutionError::InvalidCommand);
        }
        Ok(())
    }
}

pub(crate) fn validate_operation(
    attempt: &str,
    request_id: Option<&str>,
    model: &str,
    mode: Mode,
    requirements: &Requirements,
    references: &[ObjectBinding],
    metadata: [Option<&str>; 2],
) -> Result<()> {
    if !valid_string(attempt, 256)
        || request_id.is_some_and(|id| !valid_string(id, 256))
        || !valid_string(model, 128)
        || requirements
            .image_model
            .as_deref()
            .is_some_and(|model| !valid_string(model, 128))
        || (requirements.route == Route::Images
            && (requirements.vision_input || requirements.image_model.as_deref() != Some(model)))
        || references.len() > MAX_REFERENCES
        || mode == Mode::Priming
        || metadata
            .into_iter()
            .flatten()
            .any(|value| !valid_string(value, 32))
    {
        return Err(ExecutionError::InvalidCommand);
    }
    references.iter().try_for_each(ObjectBinding::validate)
}

/// Optional fields preserve the shape of historical Swift admissions.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Admission {
    pub attempt: String,
    pub owner: Owner,
    pub window: String,
    pub policy_version: String,
    pub pricing_version: String,
    pub reserved_micros: i64,
    #[serde(rename = "requestID", skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<Mode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_revision: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_snapshot: Option<AccountDispatchSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requirements: Option<Requirements>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub references: Option<Vec<ObjectBinding>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_metadata_recorded: Option<bool>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Completeness {
    #[default]
    Partial,
    Complete,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PriceCompleteness {
    Unavailable,
    Partial,
    Complete,
}

/// Trusted cumulative evidence. The adapter calculates the estimate with the rate
/// snapshot from admission. Missing usage is represented by the absence of evidence.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvidence {
    pub revision: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cached_tokens: i64,
    pub images: i64,
    pub estimated_micros: i64,
    pub completeness: Completeness,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub price_completeness: Option<PriceCompleteness>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_input_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_output_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_input_text_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_input_image_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_images: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_rejected_before_output: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub svg_input_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub svg_output_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub svg_reasoning_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub svg_author_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage_missing_reasons: Option<Vec<String>>,
}

impl UsageEvidence {
    fn counts(&self) -> [Option<i64>; 12] {
        [
            Some(self.input_tokens),
            Some(self.output_tokens),
            Some(self.cached_tokens),
            Some(self.estimated_micros),
            Some(self.images),
            self.image_input_tokens,
            self.image_output_tokens,
            self.image_input_text_tokens,
            self.image_input_image_tokens,
            self.svg_input_tokens,
            self.svg_output_tokens,
            self.svg_reasoning_tokens,
        ]
    }

    pub(crate) fn validate(&self) -> Result<()> {
        let valid_reasons = self.usage_missing_reasons.as_ref().is_none_or(|reasons| {
            reasons.len() <= 8
                && reasons.iter().enumerate().all(|(index, reason)| {
                    valid_string(reason, 64)
                        && reason.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
                        && !reasons[..index].contains(reason)
                })
        });
        if !(0..=MAX_AMOUNT).contains(&self.revision)
            || self
                .counts()
                .into_iter()
                .flatten()
                .any(|count| !(0..=MAX_AMOUNT).contains(&count))
            || self.cached_tokens > self.input_tokens
            || self.svg_reasoning_tokens.unwrap_or(0) > self.svg_output_tokens.unwrap_or(0)
            || self
                .svg_author_model
                .as_ref()
                .is_some_and(|model| !valid_model(model))
            || !valid_reasons
        {
            return Err(ExecutionError::InvalidCommand);
        }
        Ok(())
    }

    pub(crate) fn validate_for(&self, admission: &Admission) -> Result<()> {
        self.validate()?;
        if admission.requirements.as_ref().is_some_and(|requirements| {
            (requirements.route == Route::Images) != (self.native_images == Some(true))
        }) || (self.provider_rejected_before_output == Some(true)
            && (self.completeness != Completeness::Complete
                || self.counts().into_iter().flatten().any(|count| count != 0)))
        {
            return Err(ExecutionError::InvalidCommand);
        }
        Ok(())
    }

    pub(crate) fn dominates(&self, older: &Self) -> bool {
        self.counts()
            .into_iter()
            .zip(older.counts())
            .all(|(new, old)| new >= old)
            && (older.completeness != Completeness::Complete
                || self.completeness == Completeness::Complete)
            && (older.price_completeness != Some(PriceCompleteness::Complete)
                || self.price_completeness == Some(PriceCompleteness::Complete))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    AuthenticationRejected,
    RateLimited,
    UpstreamUnavailable,
    UpstreamRejected,
    InvalidUpstreamResponse,
    DeadlineExceeded,
    ClientCancelled,
    KeyRejected,
    ModelNotAllowed,
    ObjectUnavailable,
    ObjectAmbiguous,
    LocalCapacity,
    AccountUnavailable,
    StorageUnavailable,
    InvalidRequest,
    Indeterminate,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IncompleteReason {
    MaxOutputTokens,
    MaxMessages,
    ContentFilter,
    Steered,
    Unspecified,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OutcomeKind {
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub kind: OutcomeKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<Failure>,
    pub at_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_event_milliseconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_milliseconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actual_service_tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cooldown_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream_incomplete_reason: Option<IncompleteReason>,
}

impl Outcome {
    pub fn new(failure: Option<Failure>, at_unix_seconds: i64) -> Self {
        Self {
            kind: match failure {
                None => OutcomeKind::Succeeded,
                Some(Failure::ClientCancelled) => OutcomeKind::Cancelled,
                Some(_) => OutcomeKind::Failed,
            },
            failure,
            at_unix_seconds,
            first_event_milliseconds: None,
            total_milliseconds: None,
            actual_service_tier: None,
            cooldown_seconds: None,
            upstream_incomplete_reason: None,
        }
    }

    pub(crate) fn validate(&self) -> Result<()> {
        check_time(self.at_unix_seconds)?;
        if self.kind != Self::new(self.failure, self.at_unix_seconds).kind
            || self.first_event_milliseconds.is_some_and(|value| value < 0)
            || self.total_milliseconds.is_some_and(|value| value < 0)
            || self
                .actual_service_tier
                .as_ref()
                .is_some_and(|tier| !valid_string(tier, 32))
            || self.cooldown_seconds.is_some_and(|seconds| {
                !(1..=3600).contains(&seconds)
                    || !matches!(
                        self.failure,
                        Some(Failure::RateLimited | Failure::UpstreamUnavailable)
                    )
            })
            || (self.upstream_incomplete_reason.is_some()
                && self.failure != Some(Failure::Indeterminate))
        {
            return Err(ExecutionError::InvalidCommand);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Intent,
    Unknown,
    Settled,
    ClosedUnknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot {
    pub admission: Admission,
    pub state: State,
    pub usage: Option<UsageEvidence>,
    pub outcome: Option<Outcome>,
    pub created_at: Option<i64>,
    pub unknown_since: Option<i64>,
    pub closed_unknown_at: Option<i64>,
}
