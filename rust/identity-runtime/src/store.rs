use codexone_governance::{Account, AccountMode, AuthorizationState, Error, Result};
use codexone_storage::{AccountCredential, AccountCredentialCipher, AccountCredentialContext};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use crate::{
    claims::MAX_EPOCH,
    quota::{Observation, QuotaFailure, SubscriptionQuota, UsageCredits, WindowTrend},
};

pub(crate) struct Record {
    pub account: Account,
    envelope: String,
}

impl Record {
    pub fn open(&self, cipher: &AccountCredentialCipher) -> Option<AccountCredential> {
        let account = &self.account;
        let context = AccountCredentialContext::new(
            &account.id,
            &account.namespace,
            account.credential_version,
        )
        .ok()?;
        cipher.open(&self.envelope, &context).ok()
    }
}

pub(crate) fn load(db: &Connection, id: &str) -> Result<Record> {
    let mut query = db.prepare(
        "SELECT namespace, revision, credential_version, mode, authorization, sealed_credential,
                refresh_intent, created_at_epoch, display_name FROM accounts WHERE id=?",
    )?;
    let mut rows = query.query([id])?;
    let row = rows.next()?.ok_or(Error::UnknownAccount)?;
    let mode = match row.get_ref(3)?.as_str().map_err(|_| Error::Unavailable)? {
        "enabled" => AccountMode::Enabled,
        "draining" => AccountMode::Draining,
        "disabled" => AccountMode::Disabled,
        _ => return Err(Error::Unavailable),
    };
    let authorization = match row.get_ref(4)?.as_str().map_err(|_| Error::Unavailable)? {
        "ready" => AuthorizationState::Ready,
        "refreshing" => AuthorizationState::Refreshing,
        "requires_auth" => AuthorizationState::RequiresAuth,
        "auth_uncertain" => AuthorizationState::AuthUncertain,
        _ => return Err(Error::Unavailable),
    };
    Ok(Record {
        account: Account {
            id: id.into(),
            namespace: row.get(0)?,
            revision: row.get(1)?,
            credential_version: row.get(2)?,
            mode,
            authorization,
            refresh_intent: row.get(6)?,
            created_at_unix_seconds: row.get(7)?,
            display_name: row.get(8)?,
        },
        envelope: row.get(5)?,
    })
}

pub(crate) fn observation_accounts(db: &Connection) -> Result<Vec<String>> {
    let mut statement = db.prepare(
        "SELECT id FROM accounts WHERE mode IN ('enabled','draining')
         AND authorization IN ('ready','refreshing') ORDER BY id LIMIT 65",
    )?;
    let ids = statement
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if ids.len() > 64 {
        return Err(Error::Unavailable);
    }
    Ok(ids)
}

pub(crate) fn last_refresh_action(db: &Connection, id: &str, after: i64) -> Result<Option<String>> {
    Ok(db.query_row(
        "SELECT action FROM account_events WHERE account_id=? AND revision>?
         AND action IN ('refresh_begin','refresh_not_completed','refresh_commit','refresh_requires_auth','refresh_uncertain')
         ORDER BY revision DESC LIMIT 1",
        params![id, after], |row| row.get(0),
    ).optional()?)
}

pub(crate) fn load_quota(db: &Connection, id: &str) -> Result<Observation> {
    let raw: Option<String> = db
        .query_row(
            "SELECT record_json FROM account_quota WHERE account_id=?",
            [id],
            |row| row.get(0),
        )
        .optional()?;
    match raw {
        None => Ok(Observation::default()),
        Some(json) => {
            let record: Observation =
                serde_json::from_str(&json).map_err(|_| Error::Unavailable)?;
            record
                .validate()
                .then_some(record)
                .ok_or(Error::Unavailable)
        }
    }
}

pub(crate) fn record_quota(
    tx: &Transaction<'_>,
    account: &Account,
    at: i64,
    result: std::result::Result<SubscriptionQuota, QuotaFailure>,
) -> Result<Observation> {
    if !(1..=MAX_EPOCH).contains(&at) {
        return Err(Error::InvalidCommand);
    }
    let current = load(tx, &account.id)?.account;
    if account.namespace != current.namespace
        || account.credential_version != current.credential_version
        || (result.is_ok() && current.authorization != AuthorizationState::Ready)
    {
        return Err(Error::AccountConflict);
    }
    let mut observation = load_quota(tx, &account.id)?;
    let previous_attempt = observation.attempted_at_unix_seconds;
    observation.attempted_at_unix_seconds = Some(at);
    match result {
        Ok(quota) => {
            let main = quota.limits.iter().find(|limit| limit.id == "codex");
            let trend = observation.trend.get_or_insert_with(Default::default);
            for (kind, window, previous) in [
                (
                    0,
                    main.and_then(|limit| limit.primary.as_ref()),
                    &mut trend.primary,
                ),
                (
                    1,
                    main.and_then(|limit| limit.secondary.as_ref()),
                    &mut trend.secondary,
                ),
            ] {
                let latest = WindowTrend::recording(window, at, previous.as_ref());
                record_cycle(tx, &account.id, kind, previous.as_ref(), latest.as_ref())?;
                *previous = latest;
            }
            if at >= previous_attempt.unwrap_or(0) {
                record_credit(tx, &account.id, at, quota.usage_credits.as_ref())?;
            }
            observation.observed_at_unix_seconds = Some(at);
            observation.quota = Some(quota);
            observation.failure = None;
        }
        Err(failure) => observation.failure = Some(failure),
    }
    let document = encode_quota(&mut observation)?;
    tx.execute(
        "INSERT INTO account_quota VALUES(?,?) ON CONFLICT(account_id)
         DO UPDATE SET record_json=excluded.record_json",
        params![account.id, document],
    )?;
    Ok(observation)
}

fn encode_quota(observation: &mut Observation) -> Result<String> {
    loop {
        let document = serde_json::to_string(observation).map_err(|_| Error::Unavailable)?;
        if document.len() <= 16_384 {
            return Ok(document);
        }
        let trend = observation.trend.as_mut().ok_or(Error::InvalidCommand)?;
        let largest = [&mut trend.primary, &mut trend.secondary]
            .into_iter()
            .filter_map(Option::as_mut)
            .max_by_key(|trend| trend.samples.len());
        if let Some(window) = largest.filter(|window| window.samples.len() > 1) {
            window.samples.drain(..window.samples.len() / 2);
        } else {
            observation.trend = None;
        }
    }
}

fn record_credit(
    tx: &Transaction<'_>,
    id: &str,
    at: i64,
    credits: Option<&UsageCredits>,
) -> Result<()> {
    if let Some(UsageCredits::Balance { _0: balance }) = credits {
        tx.execute(
            "INSERT INTO account_credit_samples
             SELECT ?1,?2,?3,?4 WHERE NOT EXISTS
                (SELECT 1 FROM account_credit_samples WHERE account_id=?1 AND bucket_epoch>?2)
             ON CONFLICT(account_id,bucket_epoch) DO UPDATE
             SET at_epoch=excluded.at_epoch,balance=excluded.balance
             WHERE excluded.at_epoch >= account_credit_samples.at_epoch",
            params![id, at / 300, at, balance],
        )?;
    }
    tx.execute(
        "DELETE FROM account_credit_samples WHERE at_epoch<?",
        [at - 604_800],
    )?;
    Ok(())
}

fn record_cycle(
    tx: &Transaction<'_>,
    id: &str,
    kind: i64,
    previous: Option<&WindowTrend>,
    current: Option<&WindowTrend>,
) -> Result<()> {
    let stored = tx.query_row(
        "SELECT at_epoch, remaining, reset_epoch, duration_seconds FROM account_quota_cycle_samples
         WHERE account_id=? AND kind=? ORDER BY bucket_epoch DESC LIMIT 1",
        params![id, kind], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get(2)?, row.get(3)?))
        },
    ).optional()?;
    let stored = stored
        .map(|(at, remaining, reset, duration)| {
            let remaining = remaining
                .parse::<f64>()
                .ok()
                .filter(|n| (0.0..=100.0).contains(n))
                .ok_or(Error::Unavailable)?;
            Ok::<_, Error>(WindowTrend {
                reset,
                duration,
                samples: vec![(at, remaining)],
            })
        })
        .transpose()?;
    let previous = stored.as_ref().or(previous);
    let latest = current.and_then(|trend| trend.samples.last().map(|sample| (trend, *sample)));
    let continued = previous
        .zip(latest)
        .filter(|(prior, (next, sample))| prior.continues(next.reset, next.duration, *sample));
    if continued.is_none() {
        tx.execute(
            "DELETE FROM account_quota_cycle_samples WHERE account_id=? AND kind=?",
            params![id, kind],
        )?;
    }
    if let Some((next, sample)) = latest {
        let anchor = continued.map_or(next, |(prior, _)| prior);
        let insert = |(at, remaining): (i64, f64)| -> Result<()> {
            tx.execute(
                "INSERT INTO account_quota_cycle_samples VALUES(?,?,?,?,?,?,?)
                 ON CONFLICT(account_id,kind,bucket_epoch) DO UPDATE
                 SET at_epoch=excluded.at_epoch,remaining=excluded.remaining,
                     reset_epoch=excluded.reset_epoch,duration_seconds=excluded.duration_seconds
                 WHERE excluded.at_epoch >= account_quota_cycle_samples.at_epoch",
                params![
                    id,
                    kind,
                    at / 300,
                    at,
                    remaining.to_string(),
                    anchor.reset,
                    anchor.duration
                ],
            )?;
            Ok(())
        };
        if stored.is_none()
            && let Some((prior, _)) = continued
        {
            for sample in &prior.samples {
                insert(*sample)?;
            }
        }
        insert(sample)?;
        let boundary = anchor.reset - anchor.duration - 60;
        tx.execute(
            "DELETE FROM account_quota_cycle_samples WHERE account_id=? AND kind=?
             AND bucket_epoch<=? AND at_epoch<?",
            params![id, kind, boundary / 300, boundary],
        )?;
    }
    Ok(())
}

pub(crate) fn health(db: &Connection, id: &str, now: i64) -> Result<Value> {
    let failure = db.query_row(
        "SELECT coalesce(h.auth_rejected_version=a.credential_version,0),h.last_failure,h.at_epoch
         FROM account_health h JOIN accounts a ON a.id=h.account_id WHERE a.id=?",
        [id], |row| Ok((row.get::<_, bool>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
    ).optional()?;
    let mut statement = db.prepare(
        "SELECT model,until_epoch,failure FROM account_model_health
         WHERE account_id=? AND until_epoch>? ORDER BY model",
    )?;
    let cooldowns = statement
        .query_map(params![id, now], |row| {
            Ok(json!({
                "model": row.get::<_, String>(0)?,
                "untilUnixSeconds": row.get::<_, i64>(1)?,
                "failure": row.get::<_, String>(2)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({
        "authenticationRejected": failure.as_ref().is_some_and(|failure| failure.0),
        "lastFailure": failure.as_ref().map(|failure| &failure.1),
        "lastFailureAtUnixSeconds": failure.map(|failure| failure.2),
        "cooldownCount": cooldowns.len(),
        "nextCooldownEndsAtUnixSeconds": cooldowns.iter().filter_map(|row| row["untilUnixSeconds"].as_i64()).min(),
        "cooldowns": cooldowns,
    }))
}
