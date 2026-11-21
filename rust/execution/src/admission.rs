use std::{collections::HashMap, ops::ControlFlow, time::Duration};

use codexone_account_pool::{self as pool, Candidate, Health, Reference, Selection};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Deserialize;

use crate::model::*;
use crate::{AccountIdentity, ExecutionError as Error, FixedIdentity, Result};

const ACCOUNT_CONCURRENCY_LIMIT: i64 = 16;

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
        scope: KeyScope {
            models: key.policy.models.0,
            vision_input: key.policy.vision_input,
            image_generation: key.policy.image_generation,
            image_models: key.policy.image_models.0,
            reasoning_efforts: key.policy.reasoning_efforts,
        },
    })
}

pub(crate) fn credential(db: &Connection, account: &str) -> Result<AccountCredentialRecord> {
    load_credential(db, account, false)
}

fn pool_credential(db: &Connection, account: &str) -> Result<AccountCredentialRecord> {
    load_credential(db, account, true)
}

fn load_credential(
    db: &Connection,
    account: &str,
    allow_refreshing: bool,
) -> Result<AccountCredentialRecord> {
    let record = db
        .query_row(
            "SELECT namespace,revision,credential_version,
          CASE WHEN length(CAST(sealed_credential AS BLOB)) <= 49152 THEN sealed_credential END
         FROM accounts WHERE id=?1 AND (authorization='ready' OR (?2 AND authorization='refreshing'))
            AND mode IN ('enabled','draining')",
            params![account, allow_refreshing],
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
    dispatch: &AccountDispatch,
    model: &str,
    now: i64,
) -> Result<String> {
    if dispatch.id != account {
        return Err(Error::AccountUnavailable);
    }
    let snapshot = &dispatch.snapshot;
    let namespace = tx.query_row(
        "SELECT namespace FROM accounts a
         WHERE id=?1 AND revision=?2 AND credential_version=?3 AND authorization='ready' AND namespace=?7
           AND (mode='enabled' OR (mode='draining' AND ?4))
           AND NOT EXISTS (SELECT 1 FROM account_health h WHERE h.account_id=a.id AND h.auth_rejected_version=a.credential_version)
           AND NOT EXISTS (SELECT 1 FROM account_model_health h WHERE h.account_id=a.id AND h.model=?5 AND h.until_epoch>?6)",
        params![account, snapshot.revision, snapshot.credential_version, snapshot.continuation,
            model, now, dispatch.namespace],
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
    request: &ManagedAdmissionRequest,
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

fn catalog_allows(
    db: &Connection,
    account: &str,
    request: &ManagedAdmissionRequest,
) -> Result<bool> {
    if request.requirements.route != Route::Conversation {
        return Ok(true);
    }
    let denied: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM model_directory WHERE singleton=1)
          AND NOT EXISTS (
            SELECT 1 FROM model_directory_routes r WHERE model=?1 AND (account IS NULL OR account=?2)
             AND (?3 OR reasoning_efforts IS NULL OR EXISTS
               (SELECT 1 FROM json_each(r.reasoning_efforts) WHERE value=?4))
          )",
        params![request.model, account, request.mode == Mode::Warmup, request.reasoning_effort],
        |row| row.get(0),
    )?;
    Ok(!denied)
}

fn references(objects: &[ObjectBinding]) -> Vec<Reference<'_>> {
    objects
        .iter()
        .map(|object| Reference {
            kind: &object.kind,
            raw_id: &object.raw_id,
        })
        .collect()
}

pub(crate) fn resolve_hint(
    db: &Connection,
    key: &AuthenticatedKey,
    hints: &[ObjectBinding],
    now: i64,
) -> Result<Option<AccountIdentity>> {
    Ok(pool::resolve_hint(
        db,
        key.principal(),
        &references(hints),
        now,
    )?)
}

pub(crate) fn pool_credentials(
    db: &Connection,
    request: &ManagedAdmissionRequest,
    routing: &PoolRouting,
    now: i64,
) -> Result<Vec<PoolCredential>> {
    let hard = pool::resolve_affinity(
        db,
        request.key.principal(),
        &references(&request.references),
        routing.connection.as_ref(),
        now,
    )?;
    if let (Some(hard), Some(required)) = (&hard, &routing.required)
        && hard != required
    {
        return Err(Error::ContinuationOwnerUnavailable);
    }
    let restricted = hard.as_ref().or(routing.required.as_ref());
    let mut stmt = db.prepare_cached(
        "SELECT id FROM accounts WHERE authorization IN ('ready','refreshing')
           AND (mode='enabled' OR (mode='draining' AND ?1))
           AND (?2 IS NULL OR (id=?2 AND namespace=?3)) ORDER BY id LIMIT 65",
    )?;
    let mut rows = stmt.query(params![
        hard.is_some(),
        restricted.map(|identity| identity.id.as_str()),
        restricted.map(|identity| identity.namespace.as_str()),
    ])?;
    let mut eligible = Vec::new();
    while let Some(row) = rows.next()? {
        let id = row.get::<_, String>(0)?;
        if !valid_id(&id) {
            return Err(Error::StorageUnavailable);
        }
        if catalog_allows(db, &id, request)? {
            eligible.push(PoolCredential {
                record: pool_credential(db, &id)?,
                continuation: hard.is_some(),
            });
        }
    }
    if eligible.len() > 64 {
        return Err(Error::StorageUnavailable);
    }
    Ok(eligible)
}

pub(crate) fn pool_readiness_credentials(
    db: &Connection,
    now: i64,
) -> Result<Vec<AccountCredentialRecord>> {
    let mut stmt = db.prepare_cached(
        "SELECT a.id FROM accounts a WHERE a.mode='enabled' AND a.authorization='ready'
         AND NOT EXISTS (
           SELECT 1 FROM account_health h WHERE h.account_id=a.id
           AND h.auth_rejected_version=a.credential_version
         )
         AND EXISTS (
           SELECT 1 FROM health_models m
           WHERE (
             NOT EXISTS (SELECT 1 FROM model_directory WHERE singleton=1)
             OR EXISTS (SELECT 1 FROM model_directory_routes r WHERE r.model=m.model
               AND (r.account IS NULL OR r.account=a.id))
           )
           AND NOT EXISTS (
             SELECT 1 FROM account_model_health h WHERE h.account_id=a.id AND h.model=m.model
             AND h.until_epoch>?1 AND (h.failure!='upstream_unavailable' OR h.until_epoch>?2)
           )
         ) ORDER BY a.id LIMIT 65",
    )?;
    let ids = stmt
        .query_map(params![now, now + 15], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if ids.len() > 64 || ids.iter().any(|id| !valid_id(id)) {
        return Err(Error::StorageUnavailable);
    }
    ids.iter().map(|id| credential(db, id)).collect()
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

pub(crate) fn restore_allows_admission(db: &Connection, managed: bool, now: i64) -> Result<()> {
    let (present, record): (bool, Option<String>) = db.query_row(
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
    request: ManagedAdmissionRequest,
    dispatch: AccountDispatch,
    now: i64,
) -> Result<Admission> {
    let day = business_day_start(now, offset);
    check_intent(tx, &request.attempt, true, now)?;
    let namespace = account_namespace(tx, account, &dispatch, &request.model, now)?;
    if !catalog_allows(tx, account, &request)? {
        return Err(Error::Unauthorized);
    }
    key_authorizes(tx, &request, now, day, offset)?;

    let admission = managed_intent(
        &request,
        dispatch.id,
        namespace,
        Some(dispatch.snapshot),
        day,
    );
    insert_single_identity_intent(tx, admission, now)
}

pub(crate) fn admit_fixed(
    tx: &Transaction<'_>,
    identity: &FixedIdentity,
    offset: i64,
    request: ManagedAdmissionRequest,
    now: i64,
) -> Result<Admission> {
    let day = business_day_start(now, offset);
    check_intent(tx, &request.attempt, true, now)?;
    key_authorizes(tx, &request, now, day, offset)?;
    let admission = managed_intent(
        &request,
        identity.identity.clone(),
        identity.namespace.clone(),
        None,
        day,
    );
    insert_fixed_intent(tx, admission, now)
}

pub(crate) fn admit_pool(
    tx: &Transaction<'_>,
    health: &Health,
    offset: i64,
    request: ManagedAdmissionRequest,
    routing: PoolRouting,
    snapshots: Vec<AccountDispatch>,
    now_micros: i64,
) -> Result<ControlFlow<Duration, Admission>> {
    let now = now_micros.div_euclid(1_000_000);
    let day = business_day_start(now, offset);
    check_intent(tx, &request.attempt, true, now)?;
    if snapshots.is_empty() {
        return Err(Error::AccountUnavailable);
    }
    let candidates: Vec<_> = snapshots
        .into_iter()
        .map(|dispatch| Candidate {
            identity: AccountIdentity {
                id: dispatch.id,
                namespace: dispatch.namespace,
            },
            revision: dispatch.snapshot.revision,
            credential_version: dispatch.snapshot.credential_version,
            access_expires_at_unix_seconds: dispatch.snapshot.access_expires_at_unix_seconds,
            continuation: dispatch.snapshot.continuation,
        })
        .collect();
    let selection = Selection {
        principal: request.key.principal(),
        model: &request.model,
        seed: request.request_id.as_deref().unwrap_or(&request.attempt),
        candidates: &candidates,
        references: &references(&request.references),
        connection: routing.connection.as_ref(),
        required: routing.required.as_ref(),
        preferred: routing.preferred.as_ref(),
    };
    let result = pool::admit(
        tx,
        health,
        selection,
        now_micros,
        |tx, now| Ok(key_authorizes(tx, &request, now, day, offset)?),
        |tx, candidate| Ok(catalog_allows(tx, &candidate.identity.id, &request)?),
        |tx, candidate, now| {
            let identity = &candidate.identity;
            let active = active_intents(tx, &identity.namespace, &identity.id)?;
            let dispatch = AccountDispatch {
                id: identity.id.clone(),
                namespace: identity.namespace.clone(),
                snapshot: AccountDispatchSnapshot {
                    revision: candidate.revision,
                    credential_version: candidate.credential_version,
                    access_expires_at_unix_seconds: candidate.access_expires_at_unix_seconds,
                    continuation: candidate.continuation,
                },
            };
            let admission = managed_intent(
                &request,
                dispatch.id,
                dispatch.namespace,
                Some(dispatch.snapshot),
                day,
            );
            Ok(insert_intent(tx, admission, now, active)?)
        },
    );
    match result {
        Ok(admission) => Ok(ControlFlow::Continue(admission)),
        Err(PoolAdmissionError::Pacing(delay)) => Ok(ControlFlow::Break(delay)),
        Err(PoolAdmissionError::Rejected(error)) => Err(error),
    }
}

enum PoolAdmissionError {
    Rejected(Error),
    Pacing(Duration),
}

impl From<pool::Error> for PoolAdmissionError {
    fn from(error: pool::Error) -> Self {
        match error {
            pool::Error::Wait(delay) => Self::Pacing(delay),
            error => Self::Rejected(error.into()),
        }
    }
}

impl From<Error> for PoolAdmissionError {
    fn from(error: Error) -> Self {
        Self::Rejected(error)
    }
}

fn managed_intent(
    request: &ManagedAdmissionRequest,
    identity: String,
    namespace: String,
    account_snapshot: Option<AccountDispatchSnapshot>,
    day: i64,
) -> Admission {
    Admission {
        attempt: request.attempt.clone(),
        owner: Owner {
            principal: request.key.principal.clone(),
            key: request.key.id.clone(),
            namespace,
            identity,
        },
        window: format!("business-day-{day}"),
        policy_version: request.policy_version.clone(),
        pricing_version: request.pricing_version.clone(),
        reserved_micros: request.reserved_micros,
        request_id: request.request_id.clone(),
        model: Some(request.model.clone()),
        mode: Some(request.mode),
        key_revision: Some(request.key.revision),
        account_snapshot,
        requirements: Some(request.requirements.clone()),
        references: Some(request.references.clone()),
        reasoning_effort: request.reasoning_effort.clone().map(sanitize_metadata),
        service_tier: request.service_tier.clone().map(sanitize_metadata),
        request_metadata_recorded: Some(true),
    }
}

pub(crate) fn admit_static(
    tx: &Transaction<'_>,
    offset: i64,
    mut admission: Admission,
    now: i64,
) -> Result<Admission> {
    check_intent(tx, &admission.attempt, false, now)?;
    let day = business_day_start(now, offset);
    admission.window = format!("business-day-{day}");
    insert_fixed_intent(tx, admission, now)
}

fn insert_fixed_intent(tx: &Transaction<'_>, admission: Admission, now: i64) -> Result<Admission> {
    let collision: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND namespace=?2)",
        params![admission.owner.identity, admission.owner.namespace],
        |row| row.get(0),
    )?;
    if collision {
        return Err(Error::InvalidCommand);
    }
    insert_single_identity_intent(tx, admission, now)
}

fn business_day_start(now: i64, offset: i64) -> i64 {
    (now + offset).div_euclid(DAY) * DAY - offset
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

fn active_intents(tx: &Transaction<'_>, namespace: &str, identity: &str) -> Result<i64> {
    Ok(tx.query_row(
        "SELECT COUNT(*) FROM attempts WHERE namespace=?1 AND identity=?2 AND state='intent'",
        params![namespace, identity],
        |row| row.get(0),
    )?)
}

fn insert_single_identity_intent(
    tx: &Transaction<'_>,
    admission: Admission,
    now: i64,
) -> Result<Admission> {
    let owner = &admission.owner;
    let active = active_intents(tx, &owner.namespace, &owner.identity)?;
    if active >= ACCOUNT_CONCURRENCY_LIMIT {
        return Err(Error::AccountConcurrency);
    }

    // Swift's static gateway scopes references to the effective configured namespace;
    // managed routing retains its existing cross-namespace ambiguity check.
    let scope = admission
        .account_snapshot
        .is_none()
        .then_some(owner.namespace.as_str());
    for reference in admission.references.iter().flatten() {
        let binding = resolve(tx, &owner.principal, reference, scope, now)?;
        if binding.namespace != owner.namespace || binding.identity != owner.identity {
            return Err(Error::UnknownObject);
        }
        refresh_reference(tx, owner, reference, now)?;
    }
    insert_intent(tx, admission, now, active)
}

fn refresh_reference(
    tx: &Transaction<'_>,
    owner: &Owner,
    reference: &ObjectBinding,
    now: i64,
) -> Result<()> {
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
    Ok(())
}

// Call only after checking restore, authorization, capacity and reference ownership in this tx.
fn insert_intent(
    tx: &Transaction<'_>,
    admission: Admission,
    now: i64,
    active: i64,
) -> Result<Admission> {
    let owner = &admission.owner;
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
