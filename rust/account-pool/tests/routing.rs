use std::{cell::Cell, time::Duration};

use codexone_account_pool::*;
use codexone_storage::Database;
use rusqlite::{Connection, Transaction, params};

const NOW: i64 = 1_728_000_000;
const MICROS: i64 = 1_000_000;
const MODEL: &str = "synthetic-model";
const PRINCIPAL: &str = "synthetic-principal";

struct Fixture {
    db: Database,
    _directory: tempfile::TempDir,
    a: Candidate,
    b: Candidate,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open_or_create(directory.path().join("pool.sqlite")).unwrap();
        let candidate = |id: &str| {
            let identity = Identity {
                id: id.into(),
                namespace: format!("synthetic:{id}"),
            };
            db.connection().execute(
                "INSERT INTO accounts VALUES(?1,?2,1,1,'enabled','ready','synthetic-envelope',NULL,?3,NULL)",
                params![identity.id, identity.namespace, NOW],
            ).unwrap();
            Candidate {
                identity,
                revision: 1,
                credential_version: 1,
                access_expires_at_unix_seconds: NOW + 1800,
                continuation: false,
            }
        };
        let a = candidate("synthetic-a");
        let b = candidate("synthetic-b");
        db.connection()
            .execute("INSERT INTO health_models VALUES(?1)", [MODEL])
            .unwrap();
        Self {
            db,
            _directory: directory,
            a,
            b,
        }
    }
}

fn insert(db: &Connection, attempt: &str, account: &Identity, state: &str) {
    db.execute(
        "INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,reserved,state,admission_json,created_at_epoch)
         VALUES(?1,?2,'synthetic-key',?3,?4,'day','policy','pricing',0,?5,'{}',?6)",
        params![attempt, PRINCIPAL, account.namespace, account.id, state, NOW],
    ).unwrap();
}

fn selection(candidates: &[Candidate]) -> Selection<'_> {
    Selection {
        principal: PRINCIPAL,
        model: MODEL,
        seed: "synthetic-request",
        candidates,
        references: &[],
        connection: None,
        required: None,
        preferred: None,
    }
}

fn bind(db: &Connection, id: &str, owner: &Identity, reference: Reference<'_>, principal: &str) {
    insert(db, id, owner, "settled");
    db.execute(
        "INSERT INTO bindings VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![
            principal,
            owner.namespace,
            owner.id,
            reference.kind,
            reference.raw_id,
            id,
            NOW + 10
        ],
    )
    .unwrap();
}

fn choose(
    tx: &Transaction<'_>,
    health: &Health,
    request: Selection<'_>,
    micros: i64,
) -> Result<Identity> {
    admit(
        tx,
        health,
        request,
        micros,
        |_, _| Ok(()),
        |_, _| Ok(true),
        |_, chosen, _| Ok(chosen.identity.clone()),
    )
}

#[test]
fn resolves_intersection_again_in_writer_and_renews_only_selected_bindings() {
    let Fixture {
        mut db,
        _directory,
        mut a,
        mut b,
    } = Fixture::new();
    let common = Reference {
        kind: "response",
        raw_id: "same-id",
    };
    let other = Reference {
        kind: "item",
        raw_id: "owner-id",
    };
    bind(
        db.connection(),
        "original-a",
        &a.identity,
        common,
        PRINCIPAL,
    );
    assert_eq!(
        resolve_affinity(db.connection(), PRINCIPAL, &[common], None, NOW),
        Ok(Some(a.identity.clone()))
    );
    bind(
        db.connection(),
        "original-b",
        &b.identity,
        common,
        PRINCIPAL,
    );
    bind(db.connection(), "owner-b", &b.identity, other, PRINCIPAL);
    bind(db.connection(), "foreign-a", &a.identity, other, "foreign");
    db.connection()
        .execute(
            "UPDATE accounts SET mode='draining' WHERE id=?1",
            [&b.identity.id],
        )
        .unwrap();
    let health = Health::default();
    a.continuation = true;
    b.continuation = true;
    let candidates = [a.clone(), b.clone()];
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(
            &tx,
            &health,
            Selection {
                references: &[common],
                ..selection(&candidates)
            },
            NOW * MICROS
        ),
        Err(Error::AmbiguousObject)
    );
    assert_eq!(
        resolve_affinity(&tx, PRINCIPAL, &[common, other], Some(&a.identity), NOW),
        Err(Error::UnknownObject)
    );
    assert_eq!(
        resolve_hint(&tx, PRINCIPAL, &[other, common], NOW),
        Ok(Some(b.identity.clone()))
    );
    let selected = admit(
        &tx,
        &health,
        Selection {
            references: &[common, other],
            ..selection(&candidates)
        },
        NOW * MICROS,
        |_, _| Ok(()),
        |_, _| Ok(true),
        |tx, selected, _| {
            insert(tx, "continuing", &selected.identity, "intent");
            Ok::<_, Error>(selected.identity.clone())
        },
    )
    .unwrap();
    tx.commit().unwrap();
    assert_eq!(selected, b.identity);
    let renewed: i64 = db.connection().query_row(
        "SELECT COUNT(*) FROM bindings WHERE expires_at_epoch = ?1 AND identity = ?2 AND principal = ?3",
        params![NOW + 30 * 86_400, b.identity.id, PRINCIPAL], |row| row.get(0),
    ).unwrap();
    assert_eq!(renewed, 2);
    assert_eq!(
        resolve_affinity(db.connection(), PRINCIPAL, &[common], None, NOW + 10),
        Ok(Some(b.identity))
    );
}

#[test]
fn rechecks_candidate_changes_key_policy_and_live_capacity() {
    let Fixture {
        mut db,
        _directory,
        a,
        b,
    } = Fixture::new();
    let candidates = [a.clone(), b.clone()];
    let tx = db.begin_immediate().unwrap();
    let health = Health::default();
    let key_checks = Cell::new(0);
    let rejected = admit(
        &tx,
        &health,
        selection(&candidates),
        NOW * MICROS,
        |_, _| {
            key_checks.set(key_checks.get() + 1);
            Err(Error::Closed)
        },
        |_, _| Ok(true),
        |_, _, _| -> Result<()> { panic!("denied key reached ledger") },
    );
    assert_eq!(rejected, Err(Error::Closed));
    assert_eq!(key_checks.get(), 1);
    insert(&tx, "already-running", &a.identity, "intent");
    assert_eq!(
        choose(&tx, &health, selection(&candidates), NOW * MICROS),
        Ok(b.identity.clone())
    );
    assert_eq!(
        choose(
            &tx,
            &health,
            Selection {
                preferred: Some(&a.identity),
                ..selection(&candidates)
            },
            NOW * MICROS
        ),
        Ok(a.identity.clone())
    );
    for active in 2..=16 {
        insert(&tx, &format!("active-{active}"), &a.identity, "intent");
    }
    assert_eq!(
        choose(
            &tx,
            &health,
            Selection {
                preferred: Some(&a.identity),
                ..selection(&candidates)
            },
            NOW * MICROS
        ),
        Ok(b.identity.clone())
    );
    tx.execute(
        "UPDATE accounts SET revision=2 WHERE id=?1",
        [&b.identity.id],
    )
    .unwrap();
    assert_eq!(
        choose(&tx, &health, selection(&candidates), NOW * MICROS),
        Err(Error::AccountConcurrency)
    );
    tx.execute(
        "UPDATE accounts SET mode='draining',revision=1 WHERE id=?1",
        [&b.identity.id],
    )
    .unwrap();
    let pinned = Selection {
        required: Some(&b.identity),
        ..selection(&candidates)
    };
    assert_eq!(
        choose(&tx, &health, pinned, NOW * MICROS),
        Err(Error::AccountUnavailable)
    );
    assert_eq!(
        choose(
            &tx,
            &health,
            selection(&candidates),
            candidates[0].access_expires_at_unix_seconds * MICROS
        ),
        Err(Error::AccountUnavailable)
    );
}

fn stage(
    tx: &Transaction<'_>,
    health: &Health,
    candidate: &Candidate,
    outcome: HealthOutcome,
    at: i64,
    now: i64,
) -> HealthUpdate {
    health
        .record(
            tx,
            HealthObservation {
                identity: &candidate.identity,
                credential_version: candidate.credential_version,
                model: Some(MODEL),
                outcome,
                at_unix_seconds: at,
            },
            now,
        )
        .unwrap()
}

fn record(
    db: &mut Database,
    health: &mut Health,
    candidate: &Candidate,
    outcome: HealthOutcome,
    at: i64,
    now: i64,
) {
    let tx = db.begin_immediate().unwrap();
    let update = stage(&tx, health, candidate, outcome, at, now);
    tx.commit().unwrap();
    health.apply(update);
}

#[test]
fn paces_with_subsecond_deadlines_and_uses_durable_deadline_on_restart() {
    let Fixture {
        mut db,
        _directory,
        a,
        b,
    } = Fixture::new();
    let candidates = [a.clone(), b.clone()];
    let mut health = Health::default();
    let overload = HealthOutcome::UpstreamUnavailable {
        cooldown_seconds: None,
    };
    let now = NOW * MICROS + 400_000;
    let tx = db.begin_immediate().unwrap();
    let _rolled_back = stage(&tx, &health, &a, overload, NOW, now);
    tx.rollback().unwrap();
    record(&mut db, &mut health, &a, overload, NOW, now);
    let request = || Selection {
        preferred: Some(&a.identity),
        ..selection(&candidates)
    };
    let after = now + MICROS;
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, request(), now),
        Err(Error::Wait(Duration::from_secs(1)))
    );
    assert_eq!(
        choose(&tx, &health, request(), after),
        Ok(a.identity.clone())
    );
    assert_eq!(
        choose(&tx, &Health::default(), request(), after),
        Err(Error::Wait(Duration::from_millis(600)))
    );
    tx.rollback().unwrap();
    record(
        &mut db,
        &mut health,
        &a,
        overload,
        NOW + 2,
        now + 2 * MICROS,
    );
    record(
        &mut db,
        &mut health,
        &a,
        overload,
        NOW + 5,
        now + 5 * MICROS,
    );
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, request(), now + 5 * MICROS),
        Ok(b.identity.clone())
    );
    tx.rollback().unwrap();
    record(
        &mut db,
        &mut health,
        &b,
        HealthOutcome::RateLimited {
            cooldown_seconds: None,
        },
        NOW + 5,
        now + 5 * MICROS,
    );
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, request(), now + 5 * MICROS),
        Err(Error::Wait(Duration::from_secs(4)))
    );
    let rejected = admit(
        &tx,
        &health,
        request(),
        now + 5 * MICROS,
        |_, _| Err(Error::Closed),
        |_, _| Ok(true),
        |_, _, _| -> Result<()> { panic!("wait reached ledger") },
    );
    assert_eq!(rejected, Err(Error::Closed));
    tx.rollback().unwrap();
    record(
        &mut db,
        &mut health,
        &a,
        HealthOutcome::UpstreamUnavailable {
            cooldown_seconds: Some(30),
        },
        NOW + 6,
        now + 6 * MICROS,
    );
    record(
        &mut db,
        &mut health,
        &a,
        overload,
        NOW + 6,
        now + 6 * MICROS,
    );
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, request(), now + 6 * MICROS),
        Err(Error::Cooldown {
            retry_after_seconds: 30
        })
    );
    tx.rollback().unwrap();
    record(
        &mut db,
        &mut health,
        &a,
        HealthOutcome::Succeeded,
        NOW + 7,
        now + 7 * MICROS,
    );
    record(
        &mut db,
        &mut health,
        &a,
        overload,
        NOW + 8,
        now + 8 * MICROS,
    );
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, request(), now + 8 * MICROS),
        Err(Error::Wait(Duration::from_secs(1)))
    );
}

#[test]
fn stale_authentication_failure_does_not_block_reauthorized_identity() {
    let Fixture {
        mut db,
        _directory,
        mut a,
        b,
    } = Fixture::new();
    let mut health = Health::default();
    record(
        &mut db,
        &mut health,
        &a,
        HealthOutcome::AuthenticationRejected,
        NOW,
        NOW * MICROS,
    );
    let tx = db.begin_immediate().unwrap();
    assert_eq!(
        choose(&tx, &health, selection(&[a.clone()]), NOW * MICROS),
        Err(Error::AccountUnavailable)
    );
    tx.execute(
        "UPDATE accounts SET credential_version=2,revision=2 WHERE id=?1",
        [&a.identity.id],
    )
    .unwrap();
    tx.commit().unwrap();
    record(
        &mut db,
        &mut health,
        &a,
        HealthOutcome::AuthenticationRejected,
        NOW + 1,
        (NOW + 1) * MICROS,
    );
    a.credential_version = 2;
    a.revision = 2;
    let tx = db.begin_immediate().unwrap();
    let candidates = [a.clone(), b];
    assert_eq!(
        choose(
            &tx,
            &health,
            Selection {
                required: Some(&a.identity),
                ..selection(&candidates)
            },
            (NOW + 1) * MICROS
        ),
        Ok(a.identity)
    );
}
