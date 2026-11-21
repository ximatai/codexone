use std::collections::{BTreeMap, BTreeSet};
use std::fs::DirBuilder;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

use codexone_storage::{Database, require_free_space};
use rusqlite::{Connection, params};
use serde::{Deserialize, Deserializer, Serialize, de};
use serde_json::Value;

use crate::record::read_record;
use crate::{Error, MIB, Result, files, new_id, now};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ManagedKey {
    id: String,
    principal: String,
    revision: i64,
    enabled: bool,
    created_at_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_at_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    archived_at_unix_seconds: Option<i64>,
    policy: KeyPolicy,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", try_from = "StoredPolicy")]
struct KeyPolicy {
    models: Option<Vec<String>>,
    limits: KeyLimits,
    vision_input: bool,
    image_generation: bool,
    image_models: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_efforts: Option<BTreeMap<String, Vec<String>>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredPolicy {
    #[serde(deserialize_with = "Option::deserialize")]
    models: Option<Vec<String>>,
    limits: KeyLimits,
    vision_input: Option<bool>,
    image_generation: Option<bool>,
    #[serde(default = "default_image_models")]
    image_models: Option<Vec<String>>,
    reasoning_efforts: Option<BTreeMap<String, Vec<String>>>,
}

fn default_image_models() -> Option<Vec<String>> {
    Some(Vec::new())
}

impl TryFrom<StoredPolicy> for KeyPolicy {
    type Error = Error;

    fn try_from(raw: StoredPolicy) -> Result<Self> {
        let images = raw.image_generation.unwrap_or(false);
        if raw
            .models
            .as_ref()
            .is_some_and(|models| (!images && models.is_empty()) || !valid_models(models, 32))
            || raw
                .image_models
                .as_ref()
                .is_some_and(|models| (images && models.is_empty()) || !valid_models(models, 16))
            || raw.reasoning_efforts.as_ref().is_some_and(|map| {
                map.len() > 32
                    || map
                        .iter()
                        .any(|(model, efforts)| !valid_model(model) || !valid_efforts(efforts))
            })
            || [raw.limits.tokens, raw.limits.active]
                .into_iter()
                .flatten()
                .any(|limit| !(1..=crate::MAX_EPOCH).contains(&limit))
        {
            return Err(Error::Invalid);
        }
        Ok(Self {
            models: raw.models,
            limits: raw.limits,
            vision_input: raw.vision_input.unwrap_or(false),
            image_generation: images,
            image_models: raw.image_models,
            reasoning_efforts: raw.reasoning_efforts,
        })
    }
}

fn valid_models(models: &[String], maximum: usize) -> bool {
    models.len() <= maximum
        && unique(models.iter())
        && models.iter().all(|model| valid_model(model))
}

fn valid_model(model: &str) -> bool {
    (1..=128).contains(&model.len()) && !model.contains('\0')
}

fn valid_efforts(efforts: &[String]) -> bool {
    !efforts.is_empty()
        && unique(efforts.iter())
        && efforts.iter().all(|effort| {
            matches!(
                effort.as_str(),
                "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
            )
        })
}

fn unique<'a, T: Ord + 'a>(items: impl Iterator<Item = &'a T>) -> bool {
    let mut seen = BTreeSet::new();
    items.into_iter().all(|item| seen.insert(item))
}

#[derive(Serialize)]
struct KeyLimits {
    tokens: Option<i64>,
    active: Option<i64>,
}

impl<'de> Deserialize<'de> for KeyLimits {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> std::result::Result<Self, D::Error> {
        let raw = BTreeMap::<String, Value>::deserialize(decoder)?;
        let decode = |key: &str| -> std::result::Result<Option<i64>, D::Error> {
            match raw.get(key) {
                Some(Value::Null) => Ok(None),
                Some(value) => value
                    .as_i64()
                    .map(Some)
                    .ok_or_else(|| de::Error::custom("invalid Key limit")),
                None => Err(de::Error::custom("missing Key limit")),
            }
        };
        let active = decode("active")?;
        let tokens = raw
            .contains_key("tokens")
            .then(|| decode("tokens"))
            .transpose()?
            .flatten();
        if !raw.contains_key("tokens") || raw.contains_key("requests") {
            for old in ["requests", "unresolved", "budgetMicros", "unresolvedMicros"] {
                decode(old)?;
            }
        }
        Ok(Self { tokens, active })
    }
}

pub(crate) fn disable_all(db: &Connection) -> Result<()> {
    let mut statement = db.prepare(
        "SELECT CASE WHEN length(CAST(id AS BLOB))<=64 THEN id END,
                CASE WHEN length(CAST(metadata_json AS BLOB))<=16384 THEN metadata_json END
           FROM managed_keys LIMIT 257",
    )?;
    let mut rows = statement.query([])?;
    let mut keys = Vec::new();
    while let Some(row) = rows.next()? {
        if keys.len() == 256 {
            return Err(Error::Capacity);
        }
        let id: String = row.get::<_, Option<_>>(0)?.ok_or(Error::Capacity)?;
        let json: String = row.get::<_, Option<_>>(1)?.ok_or(Error::Capacity)?;
        let mut key: ManagedKey = serde_json::from_str(&json)?;
        if key.id != id
            || !(1..1_000_000).contains(&key.revision)
            || !(1..=64).contains(&key.principal.len())
        {
            return Err(Error::Invalid);
        }
        key.enabled = false;
        key.revision += 1;
        keys.push(key);
    }
    drop(rows);
    drop(statement);
    for key in keys {
        let digest = codexone_storage::key_digest(&new_id(db)?);
        db.execute(
            "UPDATE managed_keys SET digest=?1,metadata_json=?2 WHERE id=?3",
            params![digest, serde_json::to_string(&key)?, key.id],
        )?;
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportManifest {
    version: i64,
    captured_at_unix_seconds: i64,
    entries: Vec<ImportEntry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportEntry {
    id: String,
    principal: String,
    digest: String,
    policy: Value,
    source_active: bool,
    #[serde(deserialize_with = "Option::deserialize")]
    source_expires_at_unix_seconds: Option<i64>,
    policy_equivalent: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportReport {
    imported_keys: usize,
    enabled_keys: usize,
}

pub(crate) fn import(
    path: &Path,
    manifest: &Path,
    admin_digest: &[u8; 32],
) -> Result<ImportReport> {
    let manifest: ImportManifest =
        serde_json::from_slice(&files::read_bounded(manifest, MIB as usize)?)?;
    let at = now()?;
    if manifest.version != 1
        || !(at - 300..=at + 60).contains(&manifest.captured_at_unix_seconds)
        || !(1..=256).contains(&manifest.entries.len())
        || !unique(manifest.entries.iter().map(|entry| &entry.id))
        || !unique(manifest.entries.iter().map(|entry| &entry.digest))
    {
        return Err(Error::Invalid);
    }
    let admin_digest = hex::encode(admin_digest);
    let mut keys = Vec::with_capacity(manifest.entries.len());
    for entry in manifest.entries {
        let valid_id = |id: &str| id.len() <= 64 && crate::audit_reference(id);
        let valid_digest = entry.digest.len() == 64
            && entry
                .digest
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
        if !valid_id(&entry.id)
            || !valid_id(&entry.principal)
            || !valid_digest
            || entry.digest == admin_digest
            || !entry.source_active
            || !entry.policy_equivalent
            || entry.source_expires_at_unix_seconds.is_some()
        {
            return Err(Error::Invalid);
        }
        let object = entry.policy.as_object().ok_or(Error::Invalid)?;
        if object.keys().any(|key| {
            !matches!(
                key.as_str(),
                "models" | "limits" | "visionInput" | "imageGeneration" | "imageModels"
            )
        }) || !object
            .get("limits")
            .and_then(Value::as_object)
            .is_some_and(|limits| {
                limits.len() == 2 && limits.contains_key("tokens") && limits.contains_key("active")
            })
        {
            return Err(Error::Invalid);
        }
        let policy = serde_json::from_value(entry.policy)?;
        keys.push((
            ManagedKey {
                id: entry.id,
                principal: entry.principal,
                policy,
                revision: 1,
                enabled: false,
                created_at_unix_seconds: at,
                expires_at_unix_seconds: None,
                display_name: None,
                archived_at_unix_seconds: None,
            },
            entry.digest,
        ));
    }

    let directory = files::parent(path)?;
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)?;
    require_free_space(directory, 8 * MIB, true)?;
    let mut db = Database::open_for_key_import(path)?;
    let tx = db.begin_immediate()?;
    let has_history: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM managed_keys UNION ALL SELECT 1 FROM key_events
                       UNION ALL SELECT 1 FROM attempts UNION ALL SELECT 1 FROM accounts
                       UNION ALL SELECT 1 FROM maintenance_events)",
        [],
        |row| row.get(0),
    )?;
    if has_history || read_record(&tx)?.is_some() {
        return Err(Error::Conflict);
    }
    for (key, digest) in &keys {
        let metadata = serde_json::to_string(&key)?;
        tx.execute(
            "INSERT INTO managed_keys VALUES(?1,?2,?3)",
            params![key.id, digest, metadata],
        )?;
        tx.execute(
            "INSERT INTO key_events VALUES(?1,?2,?3,'import_disabled',?4,?5)",
            params![new_id(&tx)?, key.id, key.revision, at, metadata],
        )?;
    }
    tx.commit()?;
    Ok(ImportReport {
        imported_keys: keys.len(),
        enabled_keys: 0,
    })
}
