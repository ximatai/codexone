use std::collections::HashSet;
use std::sync::Arc;

use codexone_storage::key_digest;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::model::*;
use crate::{ExecutionError as Error, Result};

/// Effective values from the trusted local single-identity configuration. The
/// adapter validates the upstream URL and computes policy and pricing versions.
pub struct StaticIdentityConfig {
    pub principal: String,
    pub key_id: String,
    pub key_sha256: [u8; 32],
    pub namespace: String,
    pub identity: String,
    /// Preserve the configured URL text for Swift-compatible scope derivation.
    pub upstream_base_url: String,
    pub models: Vec<String>,
    /// True when any configured conversation model enables vision input.
    pub vision_input: bool,
    pub image_models: Vec<String>,
    pub policy_version: String,
    pub pricing_version: String,
    pub reserved_micros: i64,
}

/// Immutable policy and identity scope for the configured static Key.
pub struct StaticIdentity {
    owner: Owner,
    key_sha256: [u8; 32],
    models: HashSet<String>,
    vision_input: bool,
    image_models: HashSet<String>,
    policy_version: String,
    pricing_version: String,
    reserved_micros: i64,
}

/// The configured upstream scope used with externally managed Keys.
pub struct FixedIdentity {
    pub(crate) namespace: String,
    pub(crate) identity: String,
}

impl FixedIdentity {
    pub fn new(
        namespace: &str,
        identity: String,
        upstream_base_url: &str,
        upstream_token: Option<&str>,
    ) -> Result<Self> {
        if !valid_string(namespace, 128)
            || !valid_string(&identity, 256)
            || !valid_string(upstream_base_url, 65_536)
            || upstream_token.is_some_and(|token| {
                !(1..=16_384).contains(&token.len())
                    || !token.bytes().all(|byte| byte.is_ascii_graphic())
            })
        {
            return Err(Error::InvalidCommand);
        }
        // Both backends use Swift's slash-escaped JSON input so existing object
        // bindings survive a compatible change of executable.
        let input = Zeroizing::new(serde_json::to_string(&[
            upstream_base_url,
            "responses",
            &identity,
            upstream_token.unwrap_or("synthetic"),
        ])?);
        let swift_json = Zeroizing::new(input.replace('/', "\\/"));
        let scope = key_digest(&swift_json);
        Ok(Self {
            namespace: format!("{namespace}:{scope}"),
            identity,
        })
    }
}

impl StaticIdentity {
    /// Use the same trusted upstream token value used by the provider adapter.
    /// Only the derived scope is retained.
    pub fn new(config: StaticIdentityConfig, upstream_token: Option<&str>) -> Result<Self> {
        let models: HashSet<_> = config.models.iter().cloned().collect();
        let image_models: HashSet<_> = config.image_models.iter().cloned().collect();
        if !valid_string(&config.principal, 256)
            || !valid_string(&config.key_id, 256)
            || !valid_string(&config.policy_version, 128)
            || !valid_string(&config.pricing_version, 128)
            || !(0..=MAX_AMOUNT).contains(&config.reserved_micros)
            || !(1..=32).contains(&models.len())
            || models.len() != config.models.len()
            || image_models.len() > 16
            || image_models.len() != config.image_models.len()
            || !models.is_disjoint(&image_models)
            || models
                .iter()
                .chain(&image_models)
                .any(|model| !valid_string(model, 128))
        {
            return Err(Error::InvalidCommand);
        }

        let fixed = FixedIdentity::new(
            &config.namespace,
            config.identity,
            &config.upstream_base_url,
            upstream_token,
        )?;
        Ok(Self {
            owner: Owner {
                principal: config.principal,
                key: config.key_id,
                namespace: fixed.namespace,
                identity: fixed.identity,
            },
            key_sha256: config.key_sha256,
            models,
            vision_input: config.vision_input,
            image_models,
            policy_version: config.policy_version,
            pricing_version: config.pricing_version,
            reserved_micros: config.reserved_micros,
        })
    }

    pub fn owner(&self) -> &Owner {
        &self.owner
    }

    pub(crate) fn authenticate(self: &Arc<Self>, headers: &[&str]) -> Result<StaticAuthorization> {
        let [bearer] = headers else {
            return Err(Error::Unauthorized);
        };
        let token = bearer.strip_prefix("Bearer ").ok_or(Error::Unauthorized)?;
        if !(24..=512).contains(&token.len()) {
            return Err(Error::Unauthorized);
        }
        let digest: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        if !bool::from(self.key_sha256.ct_eq(&digest)) {
            return Err(Error::Unauthorized);
        }
        Ok(StaticAuthorization(self.clone()))
    }

    pub(crate) fn authorize(&self, request: StaticAdmissionRequest) -> Result<Admission> {
        validate_operation(
            &request.attempt,
            request.request_id.as_deref(),
            &request.model,
            request.mode,
            &request.requirements,
            &request.references,
            [
                request.reasoning_effort.as_deref(),
                request.service_tier.as_deref(),
            ],
        )?;
        let requirements = &request.requirements;
        if (requirements.route == Route::Conversation
            && (!self.models.contains(&request.model)
                || (requirements.vision_input && !self.vision_input)))
            || requirements
                .image_model
                .as_ref()
                .is_some_and(|model| !self.image_models.contains(model))
        {
            return Err(Error::Unauthorized);
        }

        Ok(Admission {
            attempt: request.attempt,
            owner: self.owner.clone(),
            window: String::new(),
            policy_version: self.policy_version.clone(),
            pricing_version: self.pricing_version.clone(),
            reserved_micros: self.reserved_micros,
            request_id: request.request_id,
            model: Some(request.model),
            mode: Some(request.mode),
            key_revision: None,
            account_snapshot: None,
            requirements: Some(request.requirements),
            references: Some(request.references),
            reasoning_effort: request.reasoning_effort.map(sanitize_metadata),
            service_tier: request.service_tier.map(sanitize_metadata),
            request_metadata_recorded: Some(true),
        })
    }
}

/// Proof of the configured static bearer, scoped to this running service.
/// It can be reused for turns of an authenticated connection.
#[derive(Clone)]
pub struct StaticAuthorization(pub(crate) Arc<StaticIdentity>);

/// Trusted request classification. The service supplies the owner, price
/// version and estimate exclusively from its configured static policy.
#[derive(Clone, Debug)]
pub struct StaticAdmissionRequest {
    pub attempt: String,
    pub request_id: Option<String>,
    pub model: String,
    pub mode: Mode,
    pub requirements: Requirements,
    pub references: Vec<ObjectBinding>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
}
