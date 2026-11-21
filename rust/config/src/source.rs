use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

use crate::ConfigError;
use crate::files::{ascii_identifier, read_private, runtime_secret, sha256, trim, unique};
use crate::runtime::is_absolute_path;
use crate::urls::is_subscription_upstream;

pub enum Source {
    SingleIdentity(Box<SingleIdentity>),
    AccountPool(Box<ResponsesConfiguration>),
}

impl Source {
    pub fn responses(&self) -> &ResponsesConfiguration {
        match self {
            Self::SingleIdentity(identity) => &identity.responses,
            Self::AccountPool(pool) => pool,
        }
    }
}

pub struct SingleIdentity {
    pub managed_keys: bool,
    pub principal: Option<String>,
    pub key_id: Option<String>,
    pub key_sha256: Option<[u8; 32]>,
    pub namespace: String,
    pub identity: String,
    pub upstream_base_url: String,
    pub upstream_token_file: Option<PathBuf>,
    pub upstream_contract: UpstreamContract,
    pub responses: ResponsesConfiguration,
}

impl SingleIdentity {
    /// Read the validated external token file again when the data service starts.
    pub fn read_upstream_token(&self) -> Result<Option<Zeroizing<String>>, ConfigError> {
        self.upstream_token_file
            .as_deref()
            .map(|path| runtime_secret(path).ok_or(ConfigError::InvalidFileOrSetting))
            .transpose()
    }
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum UpstreamContract {
    Responses,
    CodexSubscription,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum UpstreamTransport {
    Http,
    WebSocket,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Compression {
    Zstd,
    Off,
}

pub struct ResponsesConfiguration {
    pub models: Vec<Model>,
    pub image_generation: Option<ImageConfiguration>,
    pub client_fingerprint: ClientFingerprint,
    pub reserved_micros: i64,
    pub data_connections: u16,
    pub image_concurrency: u8,
    pub upstream_transport: UpstreamTransport,
    pub upstream_zstd_minimum_bytes: Option<u64>,
    pub budget: ExecutionBudget,
    budget_configured: [bool; 4],
}

impl ResponsesConfiguration {
    pub fn budget_summary(&self) -> Value {
        let budget = self.budget;
        let fields = [
            ("total", budget.total_seconds),
            ("first_response", budget.first_response_seconds),
            ("image_first_response", budget.image_first_response_seconds),
            ("progress_idle", budget.progress_seconds),
        ];
        Value::Object(fields.into_iter().zip(self.budget_configured).map(|((name, seconds), configured)| {
            (name.into(), serde_json::json!({
                "seconds": seconds, "source": if configured { "configuration" } else { "default" },
            }))
        }).collect())
    }
}

#[derive(Clone, Copy)]
pub struct ExecutionBudget {
    pub total_seconds: u16,
    pub first_response_seconds: u16,
    pub image_first_response_seconds: u16,
    pub progress_seconds: u16,
}

#[derive(Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientFingerprint {
    pub version: Option<String>,
    pub os: Option<String>,
    pub arch: Option<String>,
    pub terminal: Option<String>,
}

impl ClientFingerprint {
    fn is_valid(&self) -> bool {
        [&self.version, &self.os, &self.arch, &self.terminal]
            .into_iter()
            .flatten()
            .all(|value| {
                (1..=128).contains(&value.len())
                    && value.bytes().all(|byte| (32..=126).contains(&byte))
            })
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub id: String,
    #[serde(deserialize_with = "integer::required")]
    pub input_micros_per_million: i64,
    #[serde(deserialize_with = "integer::required")]
    pub output_micros_per_million: i64,
    pub catalog: Option<Catalog>,
    pub vision_input: Option<bool>,
    pub image_generation: Option<bool>,
    pub upstream: Option<Value>,
    pub profile_provenance: Option<ModelProfileProvenance>,
    pub reasoning_settings: Option<ModelReasoningSettings>,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct ModelReasoningSettings {
    pub allowed: Option<Vec<String>>,
    pub preferred: Option<String>,
}

impl ModelReasoningSettings {
    pub fn valid_for(&self, model: &Model) -> bool {
        let supported = model.supported_reasoning_efforts();
        let range = self
            .allowed
            .as_ref()
            .map(|allowed| allowed.iter().map(String::as_str).collect())
            .unwrap_or_else(|| supported.clone());
        !range.is_empty()
            && unique(range.iter().copied())
            && range.iter().all(|effort| supported.contains(effort))
            && self
                .preferred
                .as_deref()
                .is_none_or(|effort| range.contains(&effort))
    }
}

impl Model {
    pub fn supported_reasoning_efforts(&self) -> Vec<&str> {
        let supported = self
            .catalog
            .as_ref()
            .and_then(|catalog| catalog.reasoning_efforts.as_ref())
            .map(|efforts| efforts.iter().map(String::as_str).collect::<Vec<_>>())
            .unwrap_or_else(|| {
                self.upstream
                    .as_ref()
                    .and_then(|profile| profile.get("supported_reasoning_levels"))
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|level| level.get("effort").and_then(Value::as_str))
                    .collect()
            });
        let mut seen = std::collections::HashSet::new();
        supported
            .into_iter()
            .filter(|effort| {
                matches!(
                    *effort,
                    "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
                ) && seen.insert(*effort)
            })
            .collect()
    }

    pub fn profile_default_reasoning_effort(&self) -> Option<&str> {
        self.catalog
            .as_ref()
            .and_then(|catalog| catalog.default_reasoning_effort.as_deref())
            .or_else(|| {
                self.upstream
                    .as_ref()?
                    .get("default_reasoning_level")?
                    .as_str()
            })
    }

    pub fn effective_reasoning_efforts(&self) -> Vec<&str> {
        let mut supported = self.supported_reasoning_efforts();
        if let Some(allowed) = self
            .reasoning_settings
            .as_ref()
            .and_then(|settings| settings.allowed.as_ref())
        {
            supported.retain(|effort| allowed.iter().any(|entry| entry == *effort));
        }
        supported
    }

    pub fn effective_default_reasoning_effort(&self) -> Option<&str> {
        let effective = self.effective_reasoning_efforts();
        self.reasoning_settings
            .as_ref()
            .and_then(|settings| settings.preferred.as_deref())
            .or_else(|| self.profile_default_reasoning_effort())
            .filter(|effort| effective.contains(effort))
            .or_else(|| {
                self.reasoning_settings
                    .as_ref()?
                    .allowed
                    .as_ref()
                    .and(effective.first().copied())
            })
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub display_name: Option<String>,
    pub description: Option<String>,
    #[serde(default, deserialize_with = "integer::optional")]
    pub context_window: Option<i64>,
    #[serde(default, deserialize_with = "integer::optional")]
    pub max_context_window: Option<i64>,
    pub reasoning_efforts: Option<Vec<String>>,
    pub default_reasoning_effort: Option<String>,
    pub base_instructions: Option<String>,
}

impl Catalog {
    fn is_valid(&self) -> bool {
        let context = self.context_window.unwrap_or(32_768);
        let maximum = self.max_context_window.unwrap_or(context);
        let efforts = self.reasoning_efforts.as_deref().unwrap_or_default();
        const EFFORTS: &[&str] = &[
            "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
        ];

        self.display_name
            .as_ref()
            .is_none_or(|value| (1..=128).contains(&value.len()))
            && self
                .description
                .as_ref()
                .is_none_or(|value| value.len() <= 1024)
            && self
                .base_instructions
                .as_ref()
                .is_none_or(|value| !trim(value).is_empty() && value.len() <= 32_768)
            && (4096..=2_000_000).contains(&context)
            && (context..=2_000_000).contains(&maximum)
            && efforts.len() <= 8
            && unique(efforts.iter().map(String::as_str))
            && efforts
                .iter()
                .all(|effort| EFFORTS.contains(&effort.as_str()))
            && self
                .default_reasoning_effort
                .as_ref()
                .is_none_or(|effort| efforts.contains(effort))
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageConfiguration {
    pub default_model: String,
    pub models: Vec<ImageModel>,
}

#[derive(Clone, Copy, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum ImageSizePolicy {
    #[default]
    Fixed1536,
    Flexible3840,
}

#[derive(Clone)]
pub struct ImageModel {
    pub id: String,
    pub host_model: String,
    pub size_policy: ImageSizePolicy,
    pub supports_transparency: bool,
    pub supports_input_fidelity: bool,
    pub input_micros_per_million: i64,
    pub output_micros_per_million: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImageModelFields {
    id: String,
    host_model: Option<String>,
    size_policy: Option<ImageSizePolicy>,
    supports_transparency: Option<bool>,
    supports_input_fidelity: Option<bool>,
    #[serde(deserialize_with = "integer::required")]
    input_micros_per_million: i64,
    #[serde(deserialize_with = "integer::required")]
    output_micros_per_million: i64,
}

impl<'de> Deserialize<'de> for ImageModel {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let fields = ImageModelFields::deserialize(deserializer)?;
        Ok(Self {
            id: fields.id,
            host_model: fields.host_model.unwrap_or_default(),
            size_policy: fields.size_policy.unwrap_or_default(),
            supports_transparency: fields.supports_transparency.unwrap_or_default(),
            supports_input_fidelity: fields.supports_input_fidelity.unwrap_or_default(),
            input_micros_per_million: fields.input_micros_per_million,
            output_micros_per_million: fields.output_micros_per_million,
        })
    }
}

impl ImageConfiguration {
    pub fn is_valid(&self, hosts: &[Model]) -> bool {
        (1..=16).contains(&self.models.len())
            && unique(self.models.iter().map(|model| model.id.as_str()))
            && self
                .models
                .iter()
                .any(|model| canonically_equal(&model.id, &self.default_model))
            && self.models.iter().all(|model| {
                named(&model.id, 128)
                    && !hosts
                        .iter()
                        .any(|host| canonically_equal(&host.id, &model.id))
                    && valid_price(model.input_micros_per_million)
                    && valid_price(model.output_micros_per_million)
            })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceFields {
    client_fingerprint: Option<ClientFingerprint>,
    #[serde(default, deserialize_with = "integer::optional")]
    data_connections: Option<i64>,
    #[serde(default, deserialize_with = "integer::optional")]
    image_concurrency: Option<i64>,
    image_generation: Option<ImageConfiguration>,
    models: Vec<Model>,
    #[serde(deserialize_with = "integer::required")]
    reserved_micros: i64,
    #[serde(default, deserialize_with = "integer::optional")]
    execution_timeout_seconds: Option<i64>,
    #[serde(default, deserialize_with = "integer::optional")]
    first_response_timeout_seconds: Option<i64>,
    #[serde(default, deserialize_with = "integer::optional")]
    image_first_response_timeout_seconds: Option<i64>,
    #[serde(default, deserialize_with = "integer::optional")]
    progress_timeout_seconds: Option<i64>,
    model_profiles_file: Option<PathBuf>,
    upstream_request_compression: Option<Compression>,
    #[serde(default, deserialize_with = "integer::optional")]
    upstream_zstd_minimum_bytes: Option<i64>,
    upstream_transport: Option<UpstreamTransport>,
}

impl SourceFields {
    fn validate(&self) -> Option<ExecutionBudget> {
        let total = self.execution_timeout_seconds.unwrap_or(600);
        let first = self.first_response_timeout_seconds.unwrap_or(total.min(30));
        let image_first = self
            .image_first_response_timeout_seconds
            .unwrap_or(total.min(600));
        let progress = self.progress_timeout_seconds.unwrap_or(total.min(60));
        if !(1..=1800).contains(&total)
            || !(1..=total.min(120)).contains(&first)
            || !(1..=total.min(300)).contains(&progress)
            || !(1..=total).contains(&image_first)
            || !(8..=1024).contains(&self.data_connections.unwrap_or(128))
            || !(1..=8).contains(&self.image_concurrency.unwrap_or(2))
            || !(0..=1_000_000_000_000).contains(&self.reserved_micros)
            || self
                .upstream_zstd_minimum_bytes
                .is_some_and(|bytes| bytes < 0)
            || !self
                .client_fingerprint
                .as_ref()
                .is_none_or(ClientFingerprint::is_valid)
            || !valid_models(&self.models)
            || !self
                .image_generation
                .as_ref()
                .is_none_or(|image| image.is_valid(&self.models))
        {
            return None;
        }
        Some(ExecutionBudget {
            total_seconds: total as u16,
            first_response_seconds: first as u16,
            image_first_response_seconds: image_first as u16,
            progress_seconds: progress as u16,
        })
    }

    fn finish(mut self, now: i64) -> Option<ResponsesConfiguration> {
        if let Some(path) = self.model_profiles_file.as_deref() {
            apply_profile_snapshot(path, &mut self.models, now)?;
        }
        let budget = self.validate()?;
        Some(ResponsesConfiguration {
            models: self.models,
            image_generation: self.image_generation,
            client_fingerprint: self.client_fingerprint.unwrap_or_default(),
            reserved_micros: self.reserved_micros,
            data_connections: self.data_connections.unwrap_or(128) as u16,
            image_concurrency: self.image_concurrency.unwrap_or(2) as u8,
            upstream_transport: self.upstream_transport.unwrap_or(UpstreamTransport::Http),
            upstream_zstd_minimum_bytes: (self.upstream_request_compression
                != Some(Compression::Off))
            .then_some(self.upstream_zstd_minimum_bytes.unwrap_or(8_388_608) as u64),
            budget,
            budget_configured: [
                self.execution_timeout_seconds.is_some(),
                self.first_response_timeout_seconds.is_some(),
                self.image_first_response_timeout_seconds.is_some(),
                self.progress_timeout_seconds.is_some(),
            ],
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IdentityFields {
    principal: Option<String>,
    #[serde(rename = "keyID")]
    key_id: Option<String>,
    #[serde(rename = "keySHA256")]
    key_sha256: Option<String>,
    managed_keys: Option<bool>,
    namespace: String,
    identity: String,
    #[serde(rename = "upstreamBaseURL")]
    upstream_base_url: String,
    upstream_token_file: Option<String>,
    upstream_contract: Option<UpstreamContract>,
    #[serde(flatten)]
    common: SourceFields,
}

pub(crate) fn load_identity(path: &Path, now: i64) -> Option<SingleIdentity> {
    let config = read_json(path, 65_536)?;
    reject_persisted_model_fields(&config)?;
    let raw: IdentityFields = serde_json::from_value(config).ok()?;
    let responses = raw.common.finish(now)?;
    if !named(&raw.namespace, 128) || !named(&raw.identity, 256) {
        return None;
    }
    let managed_keys = raw.managed_keys.unwrap_or(false);
    let key_sha256 = if managed_keys {
        if raw.principal.is_some() || raw.key_id.is_some() || raw.key_sha256.is_some() {
            return None;
        }
        None
    } else {
        let digest = raw.key_sha256.as_deref()?;
        if !named(raw.principal.as_deref()?, 256)
            || !named(raw.key_id.as_deref()?, 256)
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| b"0123456789abcdef".contains(&byte))
        {
            return None;
        }
        let mut bytes = [0; 32];
        hex::decode_to_slice(digest, &mut bytes).ok()?;
        Some(bytes)
    };

    let subscription = is_subscription_upstream(&raw.upstream_base_url)?;
    let upstream_contract = raw.upstream_contract.unwrap_or(if subscription {
        UpstreamContract::CodexSubscription
    } else {
        UpstreamContract::Responses
    });
    if subscription
        && (raw.upstream_token_file.is_none()
            || upstream_contract != UpstreamContract::CodexSubscription)
    {
        return None;
    }
    let upstream_token_file = raw.upstream_token_file.map(PathBuf::from);
    if let Some(path) = &upstream_token_file {
        is_absolute_path(path.to_str()?).then_some(())?;
        runtime_secret(path)?;
    }

    Some(SingleIdentity {
        managed_keys,
        principal: raw.principal,
        key_id: raw.key_id,
        key_sha256,
        namespace: raw.namespace,
        identity: raw.identity,
        upstream_base_url: raw.upstream_base_url,
        upstream_token_file,
        upstream_contract,
        responses,
    })
}

pub(crate) fn load_pool(path: &Path, now: i64) -> Option<ResponsesConfiguration> {
    let config = read_json(path, 65_536)?;
    reject_persisted_model_fields(&config)?;
    let raw: SourceFields = serde_json::from_value(config).ok()?;
    raw.validate()?;
    raw.finish(now)
}

fn read_json(path: &Path, limit: usize) -> Option<Value> {
    let bytes = read_private(path, limit)?;
    crate::json::decode(&bytes, 128)
}

fn reject_persisted_model_fields(config: &Value) -> Option<()> {
    config
        .get("models")?
        .as_array()?
        .iter()
        .all(|model| {
            ["upstream", "profileProvenance", "reasoningSettings"]
                .iter()
                .all(|field| model.get(field).is_none())
        })
        .then_some(())
}

fn named(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.len() <= limit && !value.as_bytes().contains(&0)
}

fn valid_price(price: i64) -> bool {
    (0..=500_000_000).contains(&price)
}

fn canonically_equal(left: &str, right: &str) -> bool {
    left == right || left.nfc().eq(right.nfc())
}

pub fn valid_models(models: &[Model]) -> bool {
    (1..=32).contains(&models.len())
        && unique(models.iter().map(|model| model.id.as_str()))
        && models.iter().all(|model| {
            !model.id.is_empty()
                && model.id.len() <= 128
                && valid_price(model.input_micros_per_million)
                && valid_price(model.output_micros_per_million)
                && model
                    .reasoning_settings
                    .as_ref()
                    .is_none_or(|settings| settings.valid_for(model))
                && valid_model_profile(&model.id, model.catalog.as_ref(), model.upstream.as_ref())
        })
}

fn valid_model_profile(id: &str, catalog: Option<&Catalog>, upstream: Option<&Value>) -> bool {
    match upstream {
        Some(upstream) => {
            catalog.is_none()
                && upstream.is_object()
                && upstream
                    .get("base_instructions")
                    .and_then(Value::as_str)
                    .is_some_and(|value| !trim(value).is_empty())
                && upstream.get("slug").is_none_or(|value| {
                    value
                        .as_str()
                        .is_some_and(|slug| canonically_equal(slug, id))
                })
                && serde_json::to_vec(upstream).is_ok_and(|data| {
                    // The Swift ordered JSON writer escapes literal slashes by default.
                    data.len() + data.iter().filter(|&&byte| byte == b'/').count() <= 262_144
                })
        }
        None => catalog.is_none_or(Catalog::is_valid),
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProfileProvenance {
    pub source: String,
    pub revision: String,
    pub captured_at_unix_seconds: i64,
    pub client_versions: Vec<String>,
    #[serde(with = "profile_digest")]
    pub sha256: [u8; 32],
    pub overridden: bool,
}

mod profile_digest {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(digest: &[u8; 32], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&hex::encode(digest))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<[u8; 32], D::Error> {
        let mut digest = [0; 32];
        hex::decode_to_slice(String::deserialize(deserializer)?, &mut digest)
            .map_err(D::Error::custom)?;
        Ok(digest)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    #[serde(deserialize_with = "integer::required")]
    version: i64,
    source: String,
    revision: String,
    #[serde(deserialize_with = "integer::required")]
    captured_at_unix_seconds: i64,
    client_versions: Vec<String>,
    models: Vec<SnapshotEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnapshotEntry {
    id: String,
    catalog: Option<Catalog>,
    upstream: Option<Value>,
}

fn apply_profile_snapshot(path: &Path, models: &mut [Model], now: i64) -> Option<()> {
    let data = read_private(path, 4_194_304)?;
    let json = crate::json::decode(&data, 64)?;
    if !json
        .get("models")?
        .as_array()?
        .iter()
        .all(valid_snapshot_entry_shape)
    {
        return None;
    }
    let snapshot: Snapshot = serde_json::from_value(json).ok()?;
    if snapshot.version != 1
        || !ascii_identifier(&snapshot.source, 64)
        || !ascii_identifier(&snapshot.revision, 64)
        || !(1..=now.saturating_add(60)).contains(&snapshot.captured_at_unix_seconds)
        || !(1..=8).contains(&snapshot.client_versions.len())
        || !unique(snapshot.client_versions.iter().map(String::as_str))
        || !snapshot
            .client_versions
            .iter()
            .all(|version| ascii_identifier(version, 64))
        || !(1..=32).contains(&snapshot.models.len())
        || !unique(snapshot.models.iter().map(|entry| entry.id.as_str()))
        || !snapshot.models.iter().all(|entry| {
            !entry.id.is_empty()
                && entry.id.len() <= 128
                && valid_model_profile(&entry.id, entry.catalog.as_ref(), entry.upstream.as_ref())
                && (entry.upstream.is_some() || has_instructions(entry.catalog.as_ref()))
        })
    {
        return None;
    }
    let provenance = ModelProfileProvenance {
        source: snapshot.source,
        revision: snapshot.revision,
        captured_at_unix_seconds: snapshot.captured_at_unix_seconds,
        client_versions: snapshot.client_versions,
        sha256: sha256(&data),
        overridden: false,
    };
    let mut entries = snapshot.models;
    for model in models {
        let entry_index = entries
            .iter()
            .position(|entry| canonically_equal(&entry.id, &model.id))?;
        let entry = entries.swap_remove(entry_index);
        let overridden = model.catalog.is_some();
        if overridden && !has_instructions(model.catalog.as_ref()) {
            return None;
        }
        if !overridden {
            model.catalog = entry.catalog;
            model.upstream = entry.upstream;
        }
        model.profile_provenance = Some(ModelProfileProvenance {
            overridden,
            ..provenance.clone()
        });
    }
    Some(())
}

fn has_instructions(catalog: Option<&Catalog>) -> bool {
    catalog
        .and_then(|catalog| catalog.base_instructions.as_deref())
        .is_some_and(|instructions| !trim(instructions).is_empty())
}

fn valid_snapshot_entry_shape(entry: &Value) -> bool {
    match (entry.get("catalog"), entry.get("upstream")) {
        (Some(catalog), None) => catalog.as_object().is_some_and(|fields| {
            fields.keys().all(|key| {
                matches!(
                    key.as_str(),
                    "displayName"
                        | "description"
                        | "contextWindow"
                        | "maxContextWindow"
                        | "reasoningEfforts"
                        | "defaultReasoningEffort"
                        | "baseInstructions"
                )
            })
        }),
        (None, Some(upstream)) => upstream.is_object(),
        _ => false,
    }
}

/// Foundation accepts JSON numbers written with a decimal or exponent when they
/// represent an integer. Check the decimal digits before lowering to i64.
pub(crate) mod integer {
    use serde::{Deserialize, Deserializer, de::Error};
    use serde_json::Number;

    pub fn required<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
        let number = Number::deserialize(d)?;
        parse(&number).ok_or_else(|| D::Error::custom("invalid integer"))
    }

    pub fn optional<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
        Option::<Number>::deserialize(d)?
            .map(|number| parse(&number).ok_or_else(|| D::Error::custom("invalid integer")))
            .transpose()
    }

    pub(crate) fn parse(number: &Number) -> Option<i64> {
        if let Some(integer) = number.as_i64() {
            return Some(integer);
        }
        let text = number.as_str();
        let approximated = text.parse::<f64>().ok()?;
        let limit = 9_223_372_036_854_775_808.0;
        if approximated.abs() >= limit || approximated.fract() != 0.0 {
            return None;
        }
        let (mantissa, exponent) = match text.split_once(['e', 'E']) {
            Some((mantissa, exponent)) => (mantissa, exponent.parse::<i32>().ok()?),
            None => (text, 0),
        };
        let (negative, digits) = match mantissa.strip_prefix('-') {
            Some(digits) => (true, digits),
            None => (false, mantissa),
        };
        let (whole, fraction) = digits.split_once('.').unwrap_or((digits, ""));
        let digits = format!("{whole}{fraction}");
        let digits = digits.trim_start_matches('0');
        if digits.is_empty() {
            return Some(0);
        }
        let trailing = digits.len() - digits.trim_end_matches('0').len();
        let zeros = i64::from(exponent) - fraction.len() as i64;
        if zeros < -(trailing as i64) {
            return Some(approximated as i64);
        }
        if digits.len() as i64 + zeros > 19 {
            return None;
        }
        let mut integral = String::with_capacity(20);
        if negative {
            integral.push('-');
        }
        let retained = digits.len() - (-zeros).max(0) as usize;
        integral.push_str(&digits[..retained]);
        integral.extend(std::iter::repeat_n('0', zeros.max(0) as usize));
        integral.parse().ok()
    }
}
