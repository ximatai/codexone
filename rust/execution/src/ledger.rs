use codexone_account_pool::{Health, HealthObservation, HealthOutcome, HealthUpdate};
use codexone_storage::Database;
use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::admission::record_concurrency;
use crate::model::*;
use crate::{AccountIdentity, ExecutionError as Error, Result};

const HISTORY: i64 = 128;
const MAINTENANCE_BATCH: i64 = 100;

pub(crate) fn recover(tx: &Transaction<'_>, now: i64) -> Result<()> {
    crate::priming::recover(tx)?;
    tx.execute(
        "DELETE FROM account_concurrency
         WHERE peak<=(SELECT COUNT(*) FROM attempts a WHERE a.namespace=account_concurrency.namespace
            AND a.identity=account_concurrency.identity AND a.state='intent')",
        [],
    )?;
    tx.execute(
        "INSERT INTO account_concurrency
         SELECT namespace,identity,?1,COUNT(*) FROM attempts WHERE state='intent' GROUP BY namespace,identity
         ON CONFLICT(namespace,identity,at_epoch) DO UPDATE SET peak=MAX(peak,excluded.peak)",
        [now],
    )?;
    tx.execute(
        "UPDATE attempts SET state='unknown',unknown_since_epoch=?1 WHERE state='intent'",
        [now],
    )?;
    Ok(())
}

pub(crate) fn snapshot(db: &Connection, attempt: &str) -> Result<Snapshot> {
    let mut statement = db.prepare_cached(
        "SELECT admission_json,state,usage_json,outcome_json,created_at_epoch,unknown_since_epoch,closed_unknown_at_epoch
         FROM attempts WHERE id=?1",
    )?;
    let mut rows = statement.query([attempt])?;
    let row = rows.next()?.ok_or(Error::UnknownAttempt)?;
    let admission: Admission = serde_json::from_str(&row.get::<_, String>(0)?)?;
    if admission.attempt != attempt {
        return Err(Error::StorageUnavailable);
    }
    let state: String = row.get(1)?;
    let closed_unknown_at: Option<i64> = row.get(6)?;
    let state = match (state.as_str(), closed_unknown_at) {
        ("intent", None) => State::Intent,
        ("unknown", None) => State::Unknown,
        ("settled", None) => State::Settled,
        ("settled", Some(_)) => State::ClosedUnknown,
        _ => return Err(Error::StorageUnavailable),
    };
    let usage: Option<String> = row.get(2)?;
    let outcome: Option<String> = row.get(3)?;
    Ok(Snapshot {
        admission,
        state,
        closed_unknown_at,
        created_at: row.get(4)?,
        unknown_since: row.get(5)?,
        usage: usage.as_deref().map(serde_json::from_str).transpose()?,
        outcome: outcome.as_deref().map(serde_json::from_str).transpose()?,
    })
}

pub(crate) fn bind(
    tx: &Transaction<'_>,
    attempt: &str,
    objects: &[ObjectBinding],
    now: i64,
) -> Result<()> {
    let (principal, namespace, identity, state): (String, String, String, String) = tx
        .query_row(
            "SELECT principal,namespace,identity,state FROM attempts WHERE id=?1",
            [attempt],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?
        .ok_or(Error::UnknownAttempt)?;
    if state != "intent" {
        return Err(Error::Conflict);
    }
    for object in objects {
        tx.execute(
            "INSERT INTO bindings(principal,namespace,identity,object_type,raw_id,attempt,expires_at_epoch)
             VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(principal,namespace,identity,object_type,raw_id)
             DO UPDATE SET expires_at_epoch=excluded.expires_at_epoch",
            params![principal, namespace, identity, object.kind, object.raw_id, attempt, now + BINDING_TTL],
        )?;
    }
    Ok(())
}

fn save_evidence(
    tx: &Transaction<'_>,
    snapshot: &Snapshot,
    evidence: &UsageEvidence,
    now: i64,
) -> Result<()> {
    let attempt = &snapshot.admission.attempt;
    let revision = evidence.revision;
    let floor: i64 = tx.query_row(
        "SELECT evidence_floor FROM attempts WHERE id=?1",
        [attempt],
        |row| row.get(0),
    )?;
    if revision <= floor {
        return Err(Error::StaleEvidence);
    }
    let existing = tx
        .query_row(
            "SELECT payload FROM evidence WHERE attempt=?1 AND revision=?2",
            params![attempt, revision],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(existing) = existing {
        return if serde_json::from_str::<UsageEvidence>(&existing)? == *evidence {
            Ok(())
        } else {
            Err(Error::Conflict)
        };
    }
    if let Some(latest) = &snapshot.usage {
        let valid = match revision.cmp(&latest.revision) {
            std::cmp::Ordering::Less => latest.dominates(evidence),
            std::cmp::Ordering::Greater => evidence.dominates(latest),
            std::cmp::Ordering::Equal => latest == evidence,
        };
        if !valid {
            return Err(Error::Conflict);
        }
    }

    // Check the adjacent retained snapshots as well as the independently stored latest snapshot.
    for (sql, older) in [
        (
            "SELECT payload FROM evidence WHERE attempt=?1 AND revision<?2 ORDER BY revision DESC LIMIT 1",
            true,
        ),
        (
            "SELECT payload FROM evidence WHERE attempt=?1 AND revision>?2 ORDER BY revision ASC LIMIT 1",
            false,
        ),
    ] {
        let adjacent = tx
            .query_row(sql, params![attempt, revision], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;
        if let Some(adjacent) = adjacent {
            let adjacent = serde_json::from_str::<UsageEvidence>(&adjacent)?;
            let ordered = if older {
                evidence.dominates(&adjacent)
            } else {
                adjacent.dominates(evidence)
            };
            if !ordered {
                return Err(Error::Conflict);
            }
        }
    }

    let payload = serde_json::to_string(evidence)?;
    tx.execute(
        "INSERT INTO evidence VALUES(?1,?2,?3)",
        params![attempt, revision, payload],
    )?;
    let retired: Option<i64> = tx.query_row(
        "SELECT revision FROM evidence WHERE attempt=?1 ORDER BY revision DESC LIMIT 1 OFFSET ?2",
        params![attempt, HISTORY], |row| row.get(0),
    ).optional()?;
    if let Some(retired) = retired {
        tx.execute(
            "DELETE FROM evidence WHERE attempt=?1 AND revision<=?2",
            params![attempt, retired],
        )?;
        tx.execute(
            "UPDATE attempts SET evidence_floor=?2 WHERE id=?1",
            params![attempt, retired],
        )?;
    }
    if snapshot
        .usage
        .as_ref()
        .is_none_or(|old| revision > old.revision)
    {
        let complete = evidence.completeness == Completeness::Complete;
        let settled = complete || matches!(snapshot.state, State::Settled | State::ClosedUnknown);
        tx.execute(
            "UPDATE attempts SET state=?2,usage_json=?3,estimated=?4,
                 unknown_since_epoch=CASE WHEN ?5 THEN unknown_since_epoch ELSE COALESCE(unknown_since_epoch,?6) END,
                 closed_unknown_at_epoch=CASE WHEN ?7 THEN NULL ELSE closed_unknown_at_epoch END
             WHERE id=?1",
            params![attempt, if settled { "settled" } else { "unknown" }, payload,
                evidence.estimated_micros, settled, now, complete],
        )?;
        if evidence.images > 0 {
            tx.execute(
                "UPDATE attempts SET output_rate_settled_at=NULL,output_rate=NULL WHERE id=?1",
                [attempt],
            )?;
        } else if complete
            && evidence.output_tokens > 0
            && snapshot
                .admission
                .requirements
                .as_ref()
                .is_none_or(|r| r.route == Route::Conversation)
            && let Some(duration) = snapshot
                .outcome
                .as_ref()
                .and_then(|outcome| outcome.total_milliseconds)
            && duration > 0
        {
            // Store a decimal projection as Swift does. Monetary and token counters stay integral.
            let rate = format!(
                "{:.12}",
                evidence.output_tokens as f64 * 1000.0 / duration as f64
            );
            tx.execute(
                "UPDATE attempts SET output_rate_settled_at=?2,output_rate=?3 WHERE id=?1
                 AND output_rate_settled_at IS NULL",
                params![attempt, now, rate],
            )?;
        }
    }
    Ok(())
}

fn save_outcome(
    tx: &Transaction<'_>,
    snapshot: &Snapshot,
    outcome: &Outcome,
    health: &Health,
    now_micros: i64,
    overload_default: Option<i64>,
) -> Result<Option<HealthUpdate>> {
    if let Some(old) = &snapshot.outcome {
        return if old == outcome {
            Ok(None)
        } else {
            Err(Error::Conflict)
        };
    }
    let admission = &snapshot.admission;
    tx.execute(
        "UPDATE attempts SET outcome_json=?2 WHERE id=?1",
        params![admission.attempt, serde_json::to_string(outcome)?],
    )?;
    let Some(captured) = &admission.account_snapshot else {
        return Ok(None);
    };
    let cooldown_seconds = outcome.cooldown_seconds;
    let observation = match outcome.failure {
        None => HealthOutcome::Succeeded,
        Some(Failure::AuthenticationRejected) => HealthOutcome::AuthenticationRejected,
        Some(Failure::RateLimited) => HealthOutcome::RateLimited { cooldown_seconds },
        Some(Failure::UpstreamUnavailable) => HealthOutcome::UpstreamUnavailable {
            cooldown_seconds: cooldown_seconds.or(overload_default),
        },
        _ => return Ok(None),
    };
    let identity = AccountIdentity {
        id: admission.owner.identity.clone(),
        namespace: admission.owner.namespace.clone(),
    };
    Ok(Some(health.record(
        tx,
        HealthObservation {
            identity: &identity,
            credential_version: captured.credential_version,
            model: admission.model.as_deref(),
            outcome: observation,
            at_unix_seconds: outcome.at_unix_seconds,
        },
        now_micros,
    )?))
}

pub(crate) fn finalize(
    db: &mut Database,
    health: &mut Health,
    attempt: &str,
    evidence: Option<&UsageEvidence>,
    outcome: Option<&Outcome>,
    now_micros: i64,
    overload_default: Option<i64>,
) -> Result<()> {
    let now = now_micros.div_euclid(1_000_000);
    let tx = db.begin_immediate()?;
    let mut snapshot = snapshot(&tx, attempt)?;
    if snapshot.state == State::Intent {
        let owner = &snapshot.admission.owner;
        let active = tx.query_row(
            "SELECT COUNT(*) FROM attempts WHERE namespace=?1 AND identity=?2 AND state='intent'",
            params![owner.namespace, owner.identity],
            |row| row.get(0),
        )?;
        record_concurrency(&tx, &owner.namespace, &owner.identity, now, active)?;
    }
    let health_update = if let Some(outcome) = outcome {
        let update = save_outcome(
            &tx,
            &snapshot,
            outcome,
            health,
            now_micros,
            overload_default,
        )?;
        snapshot.outcome = Some(outcome.clone());
        update
    } else {
        None
    };
    if let Some(evidence) = evidence {
        save_evidence(&tx, &snapshot, evidence, now)?;
    } else if snapshot.state == State::Intent {
        tx.execute(
            "UPDATE attempts SET state='unknown',unknown_since_epoch=COALESCE(unknown_since_epoch,?2) WHERE id=?1",
            params![attempt, now],
        )?;
    }
    if snapshot.admission.mode == Some(Mode::Priming) {
        crate::priming::finish(&tx, attempt, outcome)?;
    }
    tx.commit()?;
    if let Some(update) = health_update {
        health.apply(update);
    }
    Ok(())
}

fn audit_release(
    tx: &Transaction<'_>,
    count: usize,
    before: i64,
    now: i64,
    reason: &str,
) -> Result<()> {
    tx.execute(
        "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES('release_unknown',?1,?2)",
        params![serde_json::json!({"released": count, "beforeUnixSeconds": before, "reason": reason}).to_string(), now],
    )?;
    Ok(())
}

pub(crate) fn expire_unknown(tx: &Transaction<'_>, now: i64) -> Result<usize> {
    let before = now - DAY;
    let count = tx.execute(
        "UPDATE attempts SET state='settled', closed_unknown_at_epoch=?1 WHERE id IN (
            SELECT id FROM attempts WHERE state='unknown' AND unknown_since_epoch<=?2
            ORDER BY unknown_since_epoch,id LIMIT ?3
         )",
        params![now, before, MAINTENANCE_BATCH],
    )?;
    if count > 0 {
        audit_release(tx, count, before, now, "reconciliation_expired")?;
    }
    Ok(count)
}

pub(crate) fn release_unknown(
    tx: &Transaction<'_>,
    before: i64,
    expected: usize,
    now: i64,
) -> Result<usize> {
    let count = tx.execute(
        "UPDATE attempts SET state='settled', closed_unknown_at_epoch=?1 WHERE state='unknown' AND created_at_epoch<?2",
        params![now, before],
    )?;
    if count != expected {
        return Err(Error::Conflict);
    }
    audit_release(tx, count, before, now, "manual")?;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_terminal_outcome_does_not_record_health_again() {
        const NOW: i64 = 1_728_000_000;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("synthetic.sqlite");
        let seed = Connection::open(&path).unwrap();
        seed.execute_batch(include_str!("../tests/swift_v19.sql"))
            .unwrap();
        seed.execute_batch(
            "INSERT INTO metadata VALUES(1,'{}');
             INSERT INTO accounts VALUES
               ('synthetic-account','synthetic-namespace',1,1,'enabled','ready','synthetic-envelope',NULL,1728000000,NULL);
             INSERT INTO health_models VALUES('synthetic-model');",
        ).unwrap();
        let admission = Admission {
            attempt: "synthetic-attempt".into(),
            owner: Owner {
                principal: "synthetic-principal".into(),
                key: "synthetic-key".into(),
                namespace: "synthetic-namespace".into(),
                identity: "synthetic-account".into(),
            },
            window: "synthetic-window".into(),
            policy_version: "synthetic-policy".into(),
            pricing_version: "synthetic-price".into(),
            reserved_micros: 0,
            request_id: None,
            model: Some("synthetic-model".into()),
            mode: Some(Mode::Generation),
            key_revision: Some(1),
            account_snapshot: Some(AccountDispatchSnapshot {
                revision: 1,
                credential_version: 1,
                access_expires_at_unix_seconds: NOW + 3600,
                continuation: false,
            }),
            requirements: None,
            references: None,
            reasoning_effort: None,
            service_tier: None,
            request_metadata_recorded: None,
        };
        seed.execute(
            "INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,
                                 pricing_version,reserved,state,admission_json,created_at_epoch)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,0,'intent',?9,?10)",
            params![
                admission.attempt,
                admission.owner.principal,
                admission.owner.key,
                admission.owner.namespace,
                admission.owner.identity,
                admission.window,
                admission.policy_version,
                admission.pricing_version,
                serde_json::to_string(&admission).unwrap(),
                NOW,
            ],
        )
        .unwrap();
        drop(seed);

        let mut db = Database::open_existing(&path).unwrap();
        let mut health = Health::default();
        let outcome = Outcome::new(Some(Failure::UpstreamUnavailable), NOW);
        let now_micros = NOW * 1_000_000 + 250_000;
        finalize(
            &mut db,
            &mut health,
            &admission.attempt,
            None,
            Some(&outcome),
            now_micros,
            None,
        )
        .unwrap();
        assert_eq!(
            snapshot(db.connection(), &admission.attempt)
                .unwrap()
                .outcome,
            Some(outcome.clone())
        );
        assert_eq!(
            db.connection()
                .query_row("SELECT until_epoch FROM account_model_health", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            NOW + 2
        );
        db.connection()
            .execute_batch(
                "CREATE TRIGGER reject_repeated_health BEFORE INSERT ON account_health
             BEGIN SELECT RAISE(ABORT,'synthetic duplicate health write'); END;",
            )
            .unwrap();
        finalize(
            &mut db,
            &mut health,
            &admission.attempt,
            None,
            Some(&outcome),
            now_micros + 1_000_000,
            None,
        )
        .unwrap();
        let conflicting = Outcome::new(Some(Failure::RateLimited), NOW);
        assert_eq!(
            finalize(
                &mut db,
                &mut health,
                &admission.attempt,
                None,
                Some(&conflicting),
                now_micros + 1_000_000,
                None,
            ),
            Err(Error::Conflict)
        );
    }
}
