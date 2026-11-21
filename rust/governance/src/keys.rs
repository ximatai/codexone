use std::collections::{BTreeMap, HashSet};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

use crate::{
    Error, Governance, Result, Work, Writer, check_revision, display_name, id, nonce, uuid,
};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Limits {
    pub tokens: Option<i64>,
    pub active: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct KeyPolicy {
    pub models: Option<Vec<String>>,
    pub limits: Limits,
    #[serde(default, deserialize_with = "nullable_bool")]
    pub vision_input: bool,
    #[serde(default, deserialize_with = "nullable_bool")]
    pub image_generation: bool,
    #[serde(default = "empty_models")]
    pub image_models: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_efforts: Option<BTreeMap<String, Vec<String>>>,
}

fn nullable_bool<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or_default())
}

#[allow(clippy::unnecessary_wraps)]
fn empty_models() -> Option<Vec<String>> {
    Some(Vec::new())
}

pub(crate) fn known_effort(effort: &str) -> bool {
    matches!(
        effort,
        "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
    )
}

impl KeyPolicy {
    pub fn validate(&self) -> Result<()> {
        fn model(name: &str) -> bool {
            !name.is_empty() && name.len() <= 128 && !name.contains('\0')
        }
        fn distinct<'a>(names: impl ExactSizeIterator<Item = &'a String>) -> bool {
            let count = names.len();
            names
                .map(|name| name.nfc().collect::<String>())
                .collect::<HashSet<_>>()
                .len()
                == count
        }
        fn models(list: &[String], capacity: usize) -> bool {
            list.len() <= capacity && list.iter().all(|name| model(name)) && distinct(list.iter())
        }
        if self
            .models
            .as_ref()
            .is_some_and(|list| !models(list, 32) || (list.is_empty() && !self.image_generation))
            || self
                .image_models
                .as_ref()
                .is_some_and(|list| !models(list, 16) || (list.is_empty() && self.image_generation))
            || self.reasoning_efforts.as_ref().is_some_and(|rules| {
                rules.len() > 32
                    || !distinct(rules.keys())
                    || rules.iter().any(|(name, efforts)| {
                        !model(name)
                            || efforts.is_empty()
                            || efforts.iter().collect::<HashSet<_>>().len() != efforts.len()
                            || efforts.iter().any(|effort| !known_effort(effort))
                    })
            })
            || [self.limits.tokens, self.limits.active]
                .into_iter()
                .flatten()
                .any(|value| !(1..=1_000_000_000_000).contains(&value))
        {
            return Err(Error::InvalidCommand);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Key {
    pub id: String,
    pub principal: String,
    pub revision: i64,
    pub enabled: bool,
    pub policy: KeyPolicy,
    pub created_at_unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived_at_unix_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
}

impl Key {
    fn decode(raw: &str) -> Result<Self> {
        let key: Self = serde_json::from_str(raw).map_err(|_| Error::Unavailable)?;
        let valid = || {
            id(&key.id)?;
            id(&key.principal)?;
            check_revision(key.revision)?;
            display_name(key.display_name.as_deref())?;
            expiration(key.expires_at_unix_seconds)?;
            key.policy.validate()?;
            if key.created_at_unix_seconds < 0
                || key
                    .archived_at_unix_seconds
                    .is_some_and(|at| at <= 0 || key.enabled)
            {
                return Err(Error::InvalidCommand);
            }
            Ok(())
        };
        valid().map_err(|_| Error::Unavailable)?;
        Ok(key)
    }
}

pub enum KeyChange {
    Policy {
        enabled: bool,
        policy: KeyPolicy,
        catalog_revision: Option<i64>,
    },
    DisplayName(Option<String>),
    Expiration(Option<i64>),
    Archive(bool),
}

impl<W: Writer> Governance<W> {
    pub async fn list_keys(&self, after: Option<String>, archived: bool) -> Result<Vec<Key>> {
        if let Some(after) = &after {
            id(after)?;
        }
        self.writer
            .run(Work::Read, move |db, _, _| {
                let mut statement = db.connection().prepare(
                    "SELECT metadata_json FROM managed_keys WHERE id>? AND
                 (json_extract(metadata_json,'$.archivedAtUnixSeconds') IS NOT NULL)=?
                 ORDER BY id LIMIT 64",
                )?;
                let mut rows = statement.query(params![after.unwrap_or_default(), archived])?;
                let mut keys = Vec::new();
                while let Some(row) = rows.next()? {
                    keys.push(Key::decode(&row.get::<_, String>(0)?)?);
                }
                Ok(keys)
            })
            .await
    }

    /// Returns the one-time secret only after its digest and audit are committed.
    pub async fn issue_key(
        &self,
        principal: String,
        policy: KeyPolicy,
        catalog_revision: Option<i64>,
    ) -> Result<(Key, Zeroizing<String>)> {
        id(&principal)?;
        policy.validate()?;
        let secret = key_secret()?;
        let digest = codexone_storage::key_digest(&secret);
        let key = self
            .writer
            .run(Work::Optional, move |db, now, _| {
                let tx = db.begin_immediate()?;
                catalog(&tx, catalog_revision)?;
                capacity(&tx, false)?;
                if tx.query_row("SELECT COUNT(*) FROM managed_keys", [], |row| {
                    row.get::<_, i64>(0)
                })? >= 256
                {
                    return Err(Error::Capacity);
                }
                let key = Key {
                    id: uuid()?,
                    principal,
                    revision: 1,
                    enabled: true,
                    policy,
                    created_at_unix_seconds: now,
                    expires_at_unix_seconds: None,
                    archived_at_unix_seconds: None,
                    display_name: None,
                };
                let collision: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM managed_keys WHERE id=? OR digest=?)",
                    params![key.id, digest],
                    |row| row.get(0),
                )?;
                if collision {
                    return Err(Error::Conflict);
                }
                let metadata = encode(&key)?;
                tx.execute(
                    "INSERT INTO managed_keys VALUES(?,?,?)",
                    params![key.id, digest, metadata],
                )?;
                audit(&tx, &key, "create", now, &metadata)?;
                tx.commit()?;
                Ok(key)
            })
            .await?;
        Ok((key, secret))
    }

    pub async fn change_key(
        &self,
        key_id: String,
        revision: i64,
        change: KeyChange,
    ) -> Result<Key> {
        id(&key_id)?;
        validate_change(revision, &change)?;
        let work = if matches!(change, KeyChange::Policy { enabled: false, .. }) {
            Work::Restrict
        } else {
            Work::Optional
        };
        self.writer
            .run(work, move |db, now, optional_allowed| {
                let tx = db.begin_immediate()?;
                let mut key = load(&tx, &key_id)?;
                if let KeyChange::Policy {
                    catalog_revision, ..
                } = &change
                {
                    catalog(&tx, *catalog_revision)?;
                }
                advance(&mut key, revision)?;
                if !matches!(change, KeyChange::Archive(false)) {
                    unarchived(&key)?;
                }
                let revoking = key.enabled && work == Work::Restrict;
                if !optional_allowed && !revoking {
                    return Err(Error::StoragePressure);
                }
                let action = match change {
                    KeyChange::Policy {
                        enabled,
                        mut policy,
                        ..
                    } => {
                        key.enabled = enabled;
                        if policy.reasoning_efforts.is_none() {
                            policy.reasoning_efforts = key.policy.reasoning_efforts.take();
                        }
                        key.policy = policy;
                        if revoking { "disable" } else { "update" }
                    }
                    KeyChange::DisplayName(name) => {
                        key.display_name = name;
                        "display_name"
                    }
                    KeyChange::Expiration(at) => {
                        key.expires_at_unix_seconds = at;
                        "expiration"
                    }
                    KeyChange::Archive(true) => {
                        if key.enabled {
                            return Err(Error::KeyEnabled);
                        }
                        key.archived_at_unix_seconds = Some(now);
                        "archive"
                    }
                    KeyChange::Archive(false) => {
                        if key.archived_at_unix_seconds.take().is_none() {
                            return Err(Error::KeyNotArchived);
                        }
                        "unarchive"
                    }
                };
                capacity(&tx, revoking)?;
                let metadata = encode(&key)?;
                tx.execute(
                    "UPDATE managed_keys SET metadata_json=? WHERE id=?",
                    params![metadata, key.id],
                )?;
                audit(&tx, &key, action, now, &metadata)?;
                tx.commit()?;
                Ok(key)
            })
            .await
    }

    pub async fn rotate_key(
        &self,
        key_id: String,
        revision: i64,
    ) -> Result<(Key, Zeroizing<String>)> {
        id(&key_id)?;
        let secret = key_secret()?;
        let digest = codexone_storage::key_digest(&secret);
        let key = self
            .writer
            .run(Work::Optional, move |db, now, _| {
                let tx = db.begin_immediate()?;
                capacity(&tx, false)?;
                let mut key = load(&tx, &key_id)?;
                advance(&mut key, revision)?;
                let collision: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM managed_keys WHERE digest=?)",
                    [&digest],
                    |row| row.get(0),
                )?;
                if collision {
                    return Err(Error::Conflict);
                }
                unarchived(&key)?;
                let metadata = encode(&key)?;
                tx.execute(
                    "UPDATE managed_keys SET digest=?,metadata_json=? WHERE id=?",
                    params![digest, metadata, key.id],
                )?;
                audit(&tx, &key, "rotate", now, &metadata)?;
                tx.commit()?;
                Ok(key)
            })
            .await?;
        Ok((key, secret))
    }
}

fn validate_change(revision: i64, change: &KeyChange) -> Result<()> {
    if let KeyChange::Policy { policy, .. } = change {
        return policy.validate();
    }
    check_revision(revision)?;
    match change {
        KeyChange::DisplayName(name) => display_name(name.as_deref()),
        KeyChange::Expiration(at) => expiration(*at),
        _ => Ok(()),
    }
}

fn expiration(value: Option<i64>) -> Result<()> {
    if value.is_some_and(|at| !(1..=1_000_000_000_000).contains(&at)) {
        return Err(Error::InvalidCommand);
    }
    Ok(())
}

fn key_secret() -> Result<Zeroizing<String>> {
    let random = nonce()?;
    Ok(Zeroizing::new(format!("co1_{}", random.as_str())))
}

fn load(db: &Connection, key_id: &str) -> Result<Key> {
    let raw: Option<String> = db
        .query_row(
            "SELECT metadata_json FROM managed_keys WHERE id=?",
            [key_id],
            |row| row.get(0),
        )
        .optional()?;
    Key::decode(&raw.ok_or(Error::Unauthorized)?)
}

fn advance(key: &mut Key, expected: i64) -> Result<()> {
    if key.revision != expected || expected >= 1_000_000 {
        return Err(Error::Conflict);
    }
    key.revision += 1;
    Ok(())
}

fn unarchived(key: &Key) -> Result<()> {
    if key.archived_at_unix_seconds.is_some() {
        return Err(Error::KeyArchived);
    }
    Ok(())
}

fn catalog(db: &Connection, expected: Option<i64>) -> Result<()> {
    if let Some(expected) = expected {
        if expected < 0 {
            return Err(Error::InvalidCommand);
        }
        let revision: i64 = db.query_row(
            "SELECT coalesce((SELECT revision FROM model_directory WHERE singleton=1),0)",
            [],
            |row| row.get(0),
        )?;
        if revision != expected {
            return Err(Error::Conflict);
        }
    }
    Ok(())
}

fn capacity(db: &Connection, revoking: bool) -> Result<()> {
    let limit = if revoking { 4352 } else { 4096 };
    if db.query_row("SELECT COUNT(*) FROM key_events", [], |row| {
        row.get::<_, i64>(0)
    })? >= limit
    {
        return Err(Error::Capacity);
    }
    Ok(())
}

fn encode(key: &Key) -> Result<String> {
    serde_json::to_string(key).map_err(|_| Error::Unavailable)
}

fn audit(db: &Connection, key: &Key, action: &str, now: i64, metadata: &str) -> Result<()> {
    db.execute(
        "INSERT INTO key_events VALUES(?,?,?,?,?,?)",
        params![uuid()?, key.id, key.revision, action, now, metadata],
    )?;
    Ok(())
}
