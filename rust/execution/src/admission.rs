use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Deserialize;

use crate::model::*;
use crate::{ExecutionError as Error, Result};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Key {
    id: String,
    principal: String,
    revision: i64,
    enabled: bool,
    expires_at_unix_seconds: Option<i64>,
    archived_at_unix_seconds: Option<i64>,
    policy: KeyPolicy,
}

#[derive(Deserialize)]
struct Nullable<T>(Option<T>);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyPolicy {
    models: Nullable<Vec<String>>,
    #[serde(default)]
    vision_input: bool,
    #[serde(default)]
    image_generation: bool,
    #[serde(default = "empty_image_list")]
    image_models: Nullable<Vec<String>>,
    reasoning_efforts: Option<HashMap<String, Vec<String>>>,
    limits: KeyLimits,
}

fn empty_image_list() -> Nullable<Vec<String>> {
    Nullable(Some(Vec::new()))
}

#[derive(Deserialize)]
struct KeyLimits {
    active: Nullable<i64>,
    tokens: Option<i64>,
}

fn checked_key(payload: Option<String>, now: i64) -> Result<Key> {
    let key: Key = serde_json::from_str(&payload.ok_or(Error::StorageUnavailable)?)?;
    if !valid_id(&key.id)
        || !valid_id(&key.principal)
        || !(1..=1_000_000).contains(&key.revision)
        || key
            .expires_at_unix_seconds
            .is_some_and(|time| check_time(time).is_err())
        || key
            .archived_at_unix_seconds
            .is_some_and(|time| time <= 0 || key.enabled)
        || [key.policy.limits.active.0, key.policy.limits.tokens]
            .into_iter()
            .flatten()
            .any(|limit| !(1..=MAX_AMOUNT).contains(&limit))
    {
        return Err(Error::StorageUnavailable);
    }
    if !key.enabled || key.archived_at_unix_seconds.is_some() {
        return Err(Error::Unauthorized);
    }
    if key.expires_at_unix_seconds.is_some_and(|time| now >= time) {
        return Err(Error::KeyExpired);
    }
    Ok(key)
}

pub(crate) fn authenticate(db: &Connection, digest: &str, now: i64) -> Result<AuthenticatedKey> {
    let (id, payload) = db.query_row(
        "SELECT id, CASE WHEN length(CAST(metadata_json AS BLOB)) <= 65536 THEN metadata_json END
         FROM managed_keys WHERE digest=?1",
        [digest],
        |row| Ok((row.get::<_, String>(0)?, row.get(1)?)),
    ).optional()?.ok_or(Error::Unauthorized)?;
    let key = checked_key(payload, now)?;
    if key.id != id {
        return Err(Error::StorageUnavailable);
    }
    Ok(AuthenticatedKey {
        id,
        principal: key.principal,
        revision: key.revision,
    })
}

pub(crate) fn credential(db: &Connection, account: &str) -> Result<AccountCredentialRecord> {
    let record = db
        .query_row(
            "SELECT namespace,revision,credential_version,
          CASE WHEN length(CAST(sealed_credential AS BLOB)) <= 49152 THEN sealed_credential END
         FROM accounts WHERE id=?1 AND authorization='ready' AND mode IN ('enabled','draining')",
            [account],
            |row| {
                Ok(AccountCredentialRecord {
                    id: account.into(),
                    namespace: row.get(0)?,
                    revision: row.get(1)?,
                    credential_version: row.get(2)?,
                    envelope: row.get(3)?,
                })
            },
        )
        .optional()?
        .ok_or(Error::AccountUnavailable)?;
    if !valid_string(&record.namespace, 512)
        || !(1..=1_000_000).contains(&record.revision)
        || !(1..=1_000_000).contains(&record.credential_version)
    {
        return Err(Error::StorageUnavailable);
    }
    Ok(record)
}

fn account_namespace(
    tx: &Transaction<'_>,
    account: &str,
    request: &AdmissionRequest,
    now: i64,
) -> Result<String> {
    if request.account.id != account {
        return Err(Error::AccountUnavailable);
    }
    let snapshot = &request.account.snapshot;
    let namespace = tx.query_row(
        "SELECT namespace FROM accounts a
         WHERE id=?1 AND revision=?2 AND credential_version=?3 AND authorization='ready' AND namespace=?7
           AND (mode='enabled' OR (mode='draining' AND ?4))
           AND NOT EXISTS (SELECT 1 FROM account_health h WHERE h.account_id=a.id AND h.auth_rejected_version=a.credential_version)
           AND NOT EXISTS (SELECT 1 FROM account_model_health h WHERE h.account_id=a.id AND h.model=?5 AND h.until_epoch>?6)",
        params![account, snapshot.revision, snapshot.credential_version, snapshot.continuation,
            request.model, now, request.account.namespace],
        |row| row.get::<_, String>(0),
    ).optional()?.ok_or(Error::AccountUnavailable)?;
    if snapshot.access_expires_at_unix_seconds <= now {
        return Err(Error::AccountUnavailable);
    }
    if !valid_string(&namespace, 512) {
        return Err(Error::StorageUnavailable);
    }
    Ok(namespace)
}

fn key_authorizes(
    tx: &Transaction<'_>,
    request: &AdmissionRequest,
    now: i64,
    day: i64,
    offset: i64,
) -> Result<()> {
    let payload = tx
        .query_row(
            "SELECT CASE WHEN length(CAST(metadata_json AS BLOB)) <= 65536 THEN metadata_json END
         FROM managed_keys WHERE id=?1",
            [&request.key.id],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(Error::Unauthorized)?;
    let key = checked_key(payload, now)?;
    if key.id != request.key.id
        || key.revision != request.key.revision
        || key.principal != request.key.principal
    {
        return Err(Error::Unauthorized);
    }
    let policy = key.policy;
    if request.requirements.route == Route::Conversation {
        if policy
            .models
            .0
            .is_some_and(|models| !models.contains(&request.model))
            || (request.requirements.vision_input && !policy.vision_input)
        {
            return Err(Error::Unauthorized);
        }
        if request.mode != Mode::Warmup
            && let Some(allowed) = policy
                .reasoning_efforts
                .as_ref()
                .and_then(|efforts| efforts.get(&request.model))
            && !request
                .reasoning_effort
                .as_ref()
                .is_some_and(|value| allowed.contains(value))
        {
            return Err(Error::Unauthorized);
        }
    }
    if let Some(model) = &request.requirements.image_model
        && (!policy.image_generation
            || policy
                .image_models
                .0
                .is_some_and(|models| !models.contains(model)))
    {
        return Err(Error::Unauthorized);
    }
    if let Some(cap) = policy.limits.active.0 {
        let active: i64 = tx.query_row(
            "SELECT COUNT(*) FROM attempts WHERE key_id=?1 AND state='intent'",
            [&key.id],
            |row| row.get(0),
        )?;
        if active >= cap {
            return Err(Error::KeyLimit);
        }
    }
    if let Some(cap) = policy.limits.tokens
        && reached_token_cap(tx, &key.id, day, offset, cap)?
    {
        return Err(Error::KeyLimit);
    }
    Ok(())
}

fn reached_token_cap(
    tx: &Transaction<'_>,
    key: &str,
    day: i64,
    offset: i64,
    cap: i64,
) -> Result<bool> {
    // Saturating accumulation also permits early exit. SQLite SUM over an arbitrary number
    // of valid evidence rows can exceed Int64; this check needs only the threshold.
    let mut query = tx.prepare_cached(
        "SELECT CASE WHEN json_extract(usage_json,'$.nativeImages')=1
                      THEN json_extract(usage_json,'$.imageInputTokens') ELSE json_extract(usage_json,'$.inputTokens') END,
                CASE WHEN json_extract(usage_json,'$.nativeImages')=1
                      THEN json_extract(usage_json,'$.imageOutputTokens') ELSE json_extract(usage_json,'$.outputTokens') END,
                json_extract(usage_json,'$.svgInputTokens'), json_extract(usage_json,'$.svgOutputTokens')
           FROM attempts WHERE key_id=?1 AND created_at_epoch>=?2 AND created_at_epoch<?3 AND usage_json IS NOT NULL
         UNION ALL
         SELECT COALESCE(input_tokens,image_input_tokens),COALESCE(output_tokens,image_output_tokens),
                svg_input_tokens,svg_output_tokens
           FROM usage_daily WHERE key_id=?1 AND day_epoch IN (?4,?5)",
    )?;
    let mut rows = query.query(params![
        key,
        day,
        day + DAY,
        day + offset,
        day.div_euclid(DAY) * DAY
    ])?;
    let mut tokens: i64 = 0;
    while let Some(row) = rows.next()? {
        for column in 0..4 {
            let count = row.get::<_, Option<i64>>(column)?.unwrap_or(0);
            if count < 0 {
                return Err(Error::StorageUnavailable);
            }
            tokens = tokens.saturating_add(count);
        }
        if tokens >= cap {
            return Ok(true);
        }
    }
    Ok(false)
}

fn catalog_authorizes(
    tx: &Transaction<'_>,
    account: &str,
    request: &AdmissionRequest,
) -> Result<()> {
    if request.requirements.route == Route::Conversation {
        let denied: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM model_directory WHERE singleton=1)
              AND NOT EXISTS (
                SELECT 1 FROM model_directory_routes r WHERE model=?1 AND (account IS NULL OR account=?2)
                 AND (?3 OR reasoning_efforts IS NULL OR EXISTS
                   (SELECT 1 FROM json_each(r.reasoning_efforts) WHERE value=?4))
              )",
            params![request.model, account, request.mode == Mode::Warmup, request.reasoning_effort],
            |row| row.get(0),
        )?;
        if denied {
            return Err(Error::Unauthorized);
        }
    }
    Ok(())
}

pub(crate) fn resolve(
    db: &Connection,
    principal: &str,
    object: &ObjectBinding,
    namespace: Option<&str>,
    now: i64,
) -> Result<Owner> {
    let mut query = db.prepare_cached(
        "SELECT b.namespace,b.identity,a.key_id FROM bindings b JOIN attempts a ON a.id=b.attempt
         WHERE b.principal=?1 AND b.object_type=?2 AND b.raw_id=?3 AND b.expires_at_epoch>?4
          AND (?5 IS NULL OR b.namespace=?5) LIMIT 2",
    )?;
    let mut rows = query.query(params![
        principal,
        object.kind,
        object.raw_id,
        now,
        namespace
    ])?;
    let row = rows.next()?.ok_or(Error::UnknownObject)?;
    let owner = Owner {
        principal: principal.into(),
        namespace: row.get(0)?,
        identity: row.get(1)?,
        key: row.get(2)?,
    };
    if rows.next()?.is_some() {
        return Err(Error::AmbiguousObject);
    }
    Ok(owner)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestoreRecord {
    id: String,
    #[serde(rename = "backupID")]
    backup_id: String,
    snapshot_unix_seconds: i64,
    restored_unix_seconds: i64,
    inherited_unresolved_requests: i64,
    inherited_unresolved_micros: i64,
    inherited_freeze_until_unix_seconds: i64,
    day_freeze_until_unix_seconds: Option<i64>,
    #[serde(default)]
    baseline_revision: i64,
    baseline: Option<RestoreBaseline>,
    reconciled_unix_seconds: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestoreBaseline {
    #[serde(rename = "restoreID")]
    restore_id: String,
    expected_revision: i64,
    audit_reference: String,
    missing_unresolved_requests: i64,
    missing_unresolved_micros: i64,
    freeze_until_unix_seconds: i64,
}

fn uuid_shape(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn restore_allows_admission(tx: &Transaction<'_>, managed: bool, now: i64) -> Result<()> {
    let (present, record): (bool, Option<String>) = tx.query_row(
        "SELECT restore_json IS NOT NULL,
          CASE WHEN length(CAST(restore_json AS BLOB))<=16384 THEN restore_json END
         FROM maintenance_state WHERE id=1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if !present {
        return Ok(());
    }
    if !managed {
        return Err(Error::MaintenanceRequired);
    }
    let record: RestoreRecord = serde_json::from_str(&record.ok_or(Error::StorageUnavailable)?)?;
    let baseline = record.baseline.ok_or(Error::MaintenanceRequired)?;
    let restored = record.restored_unix_seconds;
    if !uuid_shape(&record.id)
        || !uuid_shape(&record.backup_id)
        || !(1..=now).contains(&restored)
        || !(1..=restored).contains(&record.snapshot_unix_seconds)
        || !(0..=MAX_AMOUNT).contains(&record.inherited_freeze_until_unix_seconds)
        || !(0..=1_000_000).contains(&record.inherited_unresolved_requests)
        || !(0..=MAX_AMOUNT).contains(&record.inherited_unresolved_micros)
        || !(1..=1_000_000).contains(&record.baseline_revision)
        || record
            .day_freeze_until_unix_seconds
            .is_some_and(|freeze| !(restored + 1..=restored + DAY).contains(&freeze))
        || !record
            .reconciled_unix_seconds
            .is_some_and(|reconciled| (restored..=now).contains(&reconciled))
        || baseline.restore_id != record.id
        || baseline.expected_revision != record.baseline_revision - 1
        || !valid_string(&baseline.audit_reference, 128)
        || !baseline
            .audit_reference
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
        || !(0..=1_000_000).contains(&baseline.missing_unresolved_requests)
        || !(0..=MAX_AMOUNT).contains(&baseline.missing_unresolved_micros)
        || (baseline.missing_unresolved_requests == 0 && baseline.missing_unresolved_micros != 0)
    {
        return Err(Error::MaintenanceRequired);
    }
    let day_freeze = record
        .day_freeze_until_unix_seconds
        .unwrap_or((restored / DAY + 1) * DAY);
    let minimum = record.inherited_freeze_until_unix_seconds.max(day_freeze);
    if !(minimum..=now).contains(&baseline.freeze_until_unix_seconds) {
        return Err(Error::MaintenanceRequired);
    }
    Ok(())
}

pub(crate) fn admit(
    tx: &Transaction<'_>,
    account: &str,
    offset: i64,
    request: AdmissionRequest,
    now: i64,
) -> Result<Admission> {
    let day = (now + offset).div_euclid(DAY) * DAY - offset;
    check_intent(tx, &request.attempt, true, now)?;
    let namespace = account_namespace(tx, account, &request, now)?;
    catalog_authorizes(tx, account, &request)?;
    key_authorizes(tx, &request, now, day, offset)?;

    let admission = Admission {
        attempt: request.attempt,
        owner: Owner {
            principal: request.key.principal,
            key: request.key.id,
            namespace,
            identity: account.into(),
        },
        window: format!("business-day-{day}"),
        policy_version: request.policy_version,
        pricing_version: request.pricing_version,
        reserved_micros: request.reserved_micros,
        request_id: request.request_id,
        model: Some(request.model),
        mode: Some(request.mode),
        key_revision: Some(request.key.revision),
        account_snapshot: Some(request.account.snapshot),
        requirements: Some(request.requirements),
        references: Some(request.references),
        reasoning_effort: request.reasoning_effort.map(sanitize_metadata),
        service_tier: request.service_tier.map(sanitize_metadata),
        request_metadata_recorded: Some(true),
    };
    insert_intent(tx, admission, now)
}

pub(crate) fn admit_static(
    tx: &Transaction<'_>,
    offset: i64,
    mut admission: Admission,
    now: i64,
) -> Result<Admission> {
    check_intent(tx, &admission.attempt, false, now)?;
    let collision: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND namespace=?2)",
        params![admission.owner.identity, admission.owner.namespace],
        |row| row.get(0),
    )?;
    if collision {
        return Err(Error::InvalidCommand);
    }
    let day = (now + offset).div_euclid(DAY) * DAY - offset;
    admission.window = format!("business-day-{day}");
    insert_intent(tx, admission, now)
}

fn check_intent(tx: &Transaction<'_>, attempt: &str, managed: bool, now: i64) -> Result<()> {
    restore_allows_admission(tx, managed, now)?;
    let duplicate: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM attempts WHERE id=?1)",
        [attempt],
        |row| row.get(0),
    )?;
    if duplicate {
        return Err(Error::Conflict);
    }
    Ok(())
}

fn insert_intent(tx: &Transaction<'_>, admission: Admission, now: i64) -> Result<Admission> {
    let owner = &admission.owner;
    let active: i64 = tx.query_row(
        "SELECT COUNT(*) FROM attempts WHERE namespace=?1 AND identity=?2 AND state='intent'",
        params![owner.namespace, owner.identity],
        |row| row.get(0),
    )?;
    if active >= 16 {
        return Err(Error::AccountConcurrency);
    }

    // Swift's static gateway scopes references to the effective configured namespace;
    // managed routing retains its existing cross-namespace ambiguity check.
    let scope = admission
        .key_revision
        .is_none()
        .then_some(owner.namespace.as_str());
    for reference in admission.references.iter().flatten() {
        let binding = resolve(tx, &owner.principal, reference, scope, now)?;
        if binding.namespace != owner.namespace || binding.identity != owner.identity {
            return Err(Error::UnknownObject);
        }
        tx.execute(
            "UPDATE bindings SET expires_at_epoch=?1
             WHERE principal=?2 AND namespace=?3 AND identity=?4 AND object_type=?5 AND raw_id=?6",
            params![
                now + BINDING_TTL,
                owner.principal,
                owner.namespace,
                owner.identity,
                reference.kind,
                reference.raw_id
            ],
        )?;
    }
    tx.execute(
        "INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,
                              reserved,state,admission_json,created_at_epoch,request_id)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'intent',?10,?11,?12)",
        params![admission.attempt, owner.principal, owner.key, owner.namespace, owner.identity,
            admission.window, admission.policy_version, admission.pricing_version, admission.reserved_micros,
            serde_json::to_string(&admission)?, now, admission.request_id],
    )?;
    record_concurrency(tx, &owner.namespace, &owner.identity, now, active + 1)?;
    Ok(admission)
}

pub(crate) fn record_concurrency(
    tx: &Transaction<'_>,
    namespace: &str,
    identity: &str,
    now: i64,
    active: i64,
) -> Result<()> {
    tx.execute(
        "DELETE FROM account_concurrency WHERE namespace=?1 AND identity=?2 AND at_epoch<=?3 AND peak<=?4",
        params![namespace, identity, now, active],
    )?;
    tx.execute(
        "INSERT INTO account_concurrency VALUES(?1,?2,?3,?4)
         ON CONFLICT(namespace,identity,at_epoch) DO UPDATE SET peak=MAX(peak,excluded.peak)",
        params![namespace, identity, now, active],
    )?;
    Ok(())
}
