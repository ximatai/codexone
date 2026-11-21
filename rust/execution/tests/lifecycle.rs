use std::sync::{
    Arc,
    atomic::{AtomicI64, Ordering},
};
use std::time::Duration;
use std::{future::Future, path::PathBuf, pin::Pin};

use codexone_execution::*;
use codexone_storage::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, Database, DatabaseError,
    key_digest,
};
use rusqlite::{Connection, params};
use serde_json::{Value, json};

const NOW: i64 = 1_728_000_000;
const SECRET: &str = "co1_synthetic-execution-key";
const SECOND: &str = "co1_synthetic-next-managed-key";
const FOREIGN: &str = "co1_synthetic-other-managed-key";
const ACCOUNT: &str = "synthetic-account";
const NAMESPACE: &str = "https://upstream.test/v1/responses#synthetic-account";
const MODEL: &str = "synthetic-model";
const IMAGE_MODEL: &str = "synthetic-image";
const OTHER_ACCOUNT: &str = "synthetic-other-account";
const OTHER_NAMESPACE: &str = "https://upstream.test/v1/responses#synthetic-other-account";

struct Fixture {
    _dir: tempfile::TempDir,
    db: PathBuf,
    clock: Arc<AtomicI64>,
}

impl Fixture {
    fn new(active: Option<i64>, tokens: Option<i64>) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("synthetic.sqlite");
        let connection = Connection::open(&db).unwrap();
        connection
            .execute_batch(include_str!("swift_v19.sql"))
            .unwrap();
        connection.execute("INSERT INTO metadata VALUES(1,?1)", [json!({
            "requests": 1, "active": 1, "unresolved": 1, "budgetMicros": 1, "unresolvedMicros": 1
        }).to_string()]).unwrap();
        connection.execute(
            "INSERT INTO accounts VALUES (?1,?2,1,1,'enabled','ready','synthetic-envelope',NULL,?3,NULL)",
            params![ACCOUNT, NAMESPACE, NOW],
        ).unwrap();
        connection
            .execute("INSERT INTO model_directory VALUES(1,1,'{}')", [])
            .unwrap();
        connection
            .execute(
                "INSERT INTO model_directory_routes VALUES(?1,?2,'[\"high\"]')",
                params![MODEL, ACCOUNT],
            )
            .unwrap();
        let key = |id, principal, secret, policy: Value| {
            connection
                .execute(
                    "INSERT INTO managed_keys VALUES(?1,?2,?3)",
                    params![
                        id,
                        key_digest(secret),
                        json!({
                            "id": id, "principal": principal, "enabled": true, "revision": 1,
                            "createdAtUnixSeconds": NOW, "policy": policy
                        })
                        .to_string()
                    ],
                )
                .unwrap();
        };
        let policy = json!({
            "models": [MODEL], "limits": {"active":active, "tokens":tokens}, "visionInput": true,
            "imageGeneration": true, "imageModels": [IMAGE_MODEL], "reasoningEfforts": {MODEL: ["high"]}
        });
        key(
            "synthetic-key",
            "synthetic-principal",
            SECRET,
            policy.clone(),
        );
        key(
            "synthetic-next",
            "synthetic-principal",
            SECOND,
            policy.clone(),
        );
        key("synthetic-other", "other-principal", FOREIGN, policy);
        Self {
            _dir: dir,
            db,
            clock: Arc::new(AtomicI64::new(NOW)),
        }
    }

    fn configure_pool(&self, cipher: &AccountCredentialCipher) {
        let db = self.raw();
        let seal = |id, namespace| {
            let credential = AccountCredential::new(
                format!("access-{id}"),
                "synthetic-refresh".into(),
                None,
                NOW + 3600,
            )
            .unwrap();
            let context = AccountCredentialContext::new(id, namespace, 1).unwrap();
            cipher.seal(&credential, &context).unwrap()
        };
        db.execute(
            "UPDATE accounts SET sealed_credential=?1 WHERE id=?2",
            params![seal(ACCOUNT, NAMESPACE), ACCOUNT],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts VALUES (?1,?2,1,1,'enabled','ready',?3,NULL,?4,NULL)",
            params![
                OTHER_ACCOUNT,
                OTHER_NAMESPACE,
                seal(OTHER_ACCOUNT, OTHER_NAMESPACE),
                NOW
            ],
        )
        .unwrap();
        db.execute("UPDATE model_directory_routes SET account=NULL", [])
            .unwrap();
    }

    async fn open_pool(&self, capacity: usize) -> ExecutionService {
        let clock = self.clock.clone();
        ExecutionService::open(
            &self.db,
            Options::for_account_pool()
                .with_finalization_capacity(capacity)
                .with_clock_micros(move || clock.load(Ordering::SeqCst) * 1_000_000 + 250_000),
        )
        .await
        .unwrap()
    }

    fn raw(&self) -> Connection {
        let db = Connection::open(&self.db).unwrap();
        db.busy_timeout(Duration::from_secs(1)).unwrap();
        db
    }

    async fn open(&self, capacity: usize, hours: i8) -> ExecutionService {
        let clock = self.clock.clone();
        ExecutionService::open(
            &self.db,
            Options::new(ACCOUNT)
                .with_finalization_capacity(capacity)
                .with_business_day_offset_hours(hours)
                .with_clock(move || clock.load(Ordering::SeqCst)),
        )
        .await
        .unwrap()
    }

    fn advance(&self, seconds: i64) {
        self.clock.fetch_add(seconds, Ordering::SeqCst);
    }

    fn set_now(&self, time: i64) {
        self.clock.store(time, Ordering::SeqCst);
    }
}

async fn request(service: &ExecutionService, id: &str, secret: &str) -> AdmissionRequest {
    let key = service
        .authenticate(&[&format!("Bearer {secret}")])
        .await
        .unwrap();
    let credential = service.account_credential().await.unwrap();
    assert_eq!(credential.id(), ACCOUNT);
    assert_eq!(credential.sealed_credential(), "synthetic-envelope");
    let account = credential.dispatch_snapshot(NOW + 999_999, false);
    let request = operation(id, key);
    AdmissionRequest {
        attempt: request.attempt,
        request_id: request.request_id,
        key: request.key,
        account,
        model: request.model,
        mode: request.mode,
        requirements: request.requirements,
        references: request.references,
        reasoning_effort: request.reasoning_effort,
        service_tier: request.service_tier,
        policy_version: request.policy_version,
        pricing_version: request.pricing_version,
        reserved_micros: request.reserved_micros,
    }
}

fn operation(id: &str, key: AuthenticatedKey) -> ManagedAdmissionRequest {
    ManagedAdmissionRequest {
        attempt: id.into(),
        request_id: Some(format!("request-{id}")),
        key,
        model: MODEL.into(),
        mode: Mode::Generation,
        requirements: Requirements::default(),
        references: vec![],
        reasoning_effort: Some("high".into()),
        service_tier: None,
        policy_version: "synthetic-policy".into(),
        pricing_version: "synthetic-price".into(),
        reserved_micros: 2,
    }
}

fn synthetic_cipher() -> AccountCredentialCipher {
    AccountCredentialCipher::from_hex(&"ab".repeat(32), &[]).unwrap()
}

async fn prepare_pool(
    service: &ExecutionService,
    request: &ManagedAdmissionRequest,
    cipher: &AccountCredentialCipher,
    routing: PoolRouting,
) -> codexone_execution::Result<PreparedPool<AccountCredential>> {
    let candidates = service
        .pool_credentials(request, &routing)
        .await?
        .into_iter()
        .map(
            |PoolCredential {
                 record,
                 continuation,
             }| {
                let context = AccountCredentialContext::new(
                    record.id(),
                    record.namespace(),
                    record.credential_version(),
                )
                .unwrap();
                let credential = cipher.open(record.sealed_credential(), &context).unwrap();
                (
                    record.dispatch_snapshot(credential.expires_at_unix_seconds(), continuation),
                    credential,
                )
            },
        )
        .collect();
    Ok(PreparedPool {
        routing,
        candidates,
    })
}

async fn admit_pool(
    service: &ExecutionService,
    request: &ManagedAdmissionRequest,
    cipher: &AccountCredentialCipher,
    routing: PoolRouting,
) -> codexone_execution::Result<(Execution, AccountCredential)> {
    service
        .admit_pool(request.clone(), || {
            prepare_pool(service, request, cipher, routing.clone())
        })
        .await
}

fn object(id: &str) -> ObjectBinding {
    ObjectBinding {
        kind: "response".into(),
        raw_id: id.into(),
    }
}

fn evidence(revision: i64, input: i64, complete: bool) -> UsageEvidence {
    UsageEvidence {
        revision,
        input_tokens: input,
        output_tokens: 2,
        cached_tokens: 1,
        estimated_micros: input * 2,
        completeness: if complete {
            Completeness::Complete
        } else {
            Completeness::Partial
        },
        ..UsageEvidence::default()
    }
}

#[tokio::test]
async fn durable_admission_binding_and_rotation_gates() {
    let fixture = Fixture::new(Some(2), None);
    let service = fixture.open(4, -5).await;
    let initial = request(&service, "first", SECRET).await;
    let mut rejected = initial.clone();
    rejected.reasoning_effort = Some("medium".into());
    assert_eq!(
        service.admit(rejected).await.err(),
        Some(ExecutionError::Unauthorized)
    );
    assert_eq!(
        service.snapshot("first").await.err(),
        Some(ExecutionError::UnknownAttempt)
    );

    let mut turn = service.admit(initial.clone()).await.unwrap();
    let row = service.snapshot("first").await.unwrap();
    assert_eq!(row.state, State::Intent);
    assert_eq!(
        row.admission.window,
        format!("business-day-{}", NOW - 19 * 3600)
    );
    assert_eq!(row.admission.pricing_version, "synthetic-price");
    assert_eq!(row.admission.reserved_micros, 2);
    assert_eq!(
        service.admit(initial.clone()).await.err(),
        Some(ExecutionError::Conflict)
    );
    assert_eq!(
        turn.bind(&[object("resp_owned")]).await,
        Err(ExecutionError::Conflict)
    );
    turn.begin_dispatch().unwrap();
    assert_eq!(turn.begin_dispatch(), Err(ExecutionError::Conflict));
    turn.bind(&[object("resp_owned"), object("resp_second")])
        .await
        .unwrap();

    let mut foreign = request(&service, "foreign", FOREIGN).await;
    foreign.references.push(object("resp_owned"));
    assert_eq!(
        service.admit(foreign).await.err(),
        Some(ExecutionError::UnknownObject)
    );
    let mut continuation = request(&service, "continuation", SECOND).await;
    continuation.references.push(object("resp_owned"));
    let db = fixture.raw();
    let expires_at = || {
        db.query_row(
            "SELECT expires_at_epoch FROM bindings WHERE raw_id='resp_owned'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap()
    };
    let original_expiry = expires_at();
    fixture.advance(1);
    let mut missing = continuation.clone();
    missing.references.push(object("resp_missing"));
    assert_eq!(
        service.admit(missing).await.err(),
        Some(ExecutionError::UnknownObject)
    );
    assert_eq!(expires_at(), original_expiry);

    let admitted = service.admit(continuation).await.unwrap();
    assert_eq!(expires_at(), original_expiry + 1);
    assert_eq!(
        admitted.admission().owner.principal,
        turn.admission().owner.principal
    );
    assert_ne!(admitted.admission().owner.key, turn.admission().owner.key);
    drop(admitted);

    let mut stale = initial.clone();
    stale.attempt = "stale-key".into();
    stale.request_id = None;
    db.execute(
        "UPDATE managed_keys SET metadata_json=json_set(metadata_json,'$.revision',2) WHERE id=?1",
        [stale.key.id()],
    )
    .unwrap();
    assert_eq!(
        service.admit(stale.clone()).await.err(),
        Some(ExecutionError::Unauthorized)
    );
    db.execute("UPDATE accounts SET mode='disabled' WHERE id=?1", [ACCOUNT])
        .unwrap();
    assert_eq!(
        service.admit(initial).await.err(),
        Some(ExecutionError::Conflict)
    );
    assert_eq!(
        service.admit(stale).await.err(),
        Some(ExecutionError::AccountUnavailable)
    );
    turn.cancel(NOW).unwrap();
    assert_eq!(
        service.snapshot("first").await.unwrap().state,
        State::Unknown
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn observed_tokens_cross_cap_and_unknown_does_not_hold_concurrency() {
    let fixture = Fixture::new(Some(1), Some(10));
    let service = fixture.open(3, 0).await;
    let mut turn = service
        .admit(request(&service, "first", SECRET).await)
        .await
        .unwrap();
    turn.begin_dispatch().unwrap();
    let second = request(&service, "second", SECRET).await;
    assert_eq!(
        service.admit(second.clone()).await.err(),
        Some(ExecutionError::KeyLimit)
    );
    turn.observe(evidence(0, 6, false)).unwrap();
    turn.cancel(NOW).unwrap();
    let snapshot = service.snapshot("first").await.unwrap();
    assert_eq!(snapshot.state, State::Unknown);
    assert_eq!(snapshot.outcome.unwrap().kind, OutcomeKind::Cancelled);
    assert_eq!(snapshot.usage.unwrap().input_tokens, 6);

    // Partial evidence counts its known lower bound, without consuming an active slot.
    let mut next = service.admit(second).await.unwrap();
    next.begin_dispatch().unwrap();
    next.observe(evidence(0, 2, true)).unwrap();
    next.finish(Some(Outcome::new(None, NOW))).unwrap();
    assert_eq!(
        service
            .admit(request(&service, "third", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::KeyLimit)
    );
    let raw = fixture.raw();
    let estimated: i64 = raw
        .query_row(
            "SELECT estimated FROM attempts WHERE id='first'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(estimated, 12);
    fixture.advance(86_400);
    drop(
        service
            .admit(request(&service, "new-day", SECRET).await)
            .await
            .unwrap(),
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn evidence_history_is_bounded_and_late_use_is_cumulative() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(2, 0).await;
    let mut turn = service
        .admit(request(&service, "bounded", SECRET).await)
        .await
        .unwrap();
    turn.begin_dispatch().unwrap();
    turn.observe(evidence(0, 1, false)).unwrap();
    drop(turn);
    for revision in 1..=130 {
        service
            .reconcile("bounded", evidence(revision, revision + 1, revision == 130))
            .await
            .unwrap();
    }
    let snapshot = service.snapshot("bounded").await.unwrap();
    assert_eq!(snapshot.state, State::Settled);
    assert_eq!(snapshot.usage.unwrap(), evidence(130, 131, true));
    assert_eq!(
        service.reconcile("bounded", evidence(2, 3, false)).await,
        Err(ExecutionError::StaleEvidence)
    );
    assert_eq!(
        service
            .reconcile("bounded", evidence(129, 128, false))
            .await,
        Err(ExecutionError::Conflict)
    );
    assert_eq!(
        service
            .reconcile("bounded", evidence(131, 132, false))
            .await,
        Err(ExecutionError::Conflict)
    );
    service
        .reconcile("bounded", evidence(130, 131, true))
        .await
        .unwrap();
    service
        .reconcile("bounded", evidence(131, 150, true))
        .await
        .unwrap();
    let record: (i64,i64,i64) = fixture.raw().query_row(
        "SELECT estimated,evidence_floor,(SELECT COUNT(*) FROM evidence) FROM attempts WHERE id='bounded'",
        [], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?)),
    ).unwrap();
    assert_eq!(record, (300, 3, 128));
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn failure_before_commit_or_during_settlement_never_loses_the_intent_barrier() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(2, 0).await;
    let db = fixture.raw();
    db.execute_batch(
        "CREATE TRIGGER admission_failure BEFORE INSERT ON account_concurrency
         BEGIN SELECT RAISE(ABORT,'synthetic admission failure'); END;",
    )
    .unwrap();
    assert_eq!(
        service
            .admit(request(&service, "rollback", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::StorageUnavailable)
    );
    assert_eq!(service.status(), ExecutionStatus::Failed);
    tokio::time::timeout(Duration::from_secs(1), service.wait_until_failed())
        .await
        .unwrap();
    assert_eq!(
        service.snapshot("rollback").await.err(),
        Some(ExecutionError::UnknownAttempt)
    );
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
    db.execute_batch("DROP TRIGGER admission_failure").unwrap();

    let service = fixture.open(2, 0).await;
    let mut turn = service
        .admit(request(&service, "interrupted", SECRET).await)
        .await
        .unwrap();
    turn.begin_dispatch().unwrap();
    turn.observe(evidence(0, 7, true)).unwrap();
    db.execute_batch(
        "CREATE TRIGGER settle_failure BEFORE UPDATE OF usage_json ON attempts
         BEGIN SELECT RAISE(ABORT,'synthetic settlement failure'); END;",
    )
    .unwrap();
    let failed = tokio::spawn({
        let service = service.clone();
        async move { service.wait_until_failed().await }
    });
    tokio::task::yield_now().await;
    turn.finish(Some(Outcome::new(
        Some(Failure::AuthenticationRejected),
        NOW,
    )))
    .unwrap();
    tokio::time::timeout(Duration::from_secs(1), failed)
        .await
        .unwrap()
        .unwrap();
    let intent = service.snapshot("interrupted").await.unwrap();
    assert_eq!(intent.state, State::Intent);
    assert_eq!(intent.outcome, None);
    assert_eq!(intent.usage, None);
    let health_rows: i64 = db
        .query_row("SELECT COUNT(*) FROM account_health", [], |row| row.get(0))
        .unwrap();
    assert_eq!(health_rows, 0);
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM evidence", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(service.status(), ExecutionStatus::Failed);
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
    db.execute_batch("DROP TRIGGER settle_failure").unwrap();

    fixture.advance(99);
    let service = fixture.open(2, 0).await;
    let recovered = service.snapshot("interrupted").await.unwrap();
    assert_eq!(recovered.state, State::Unknown);
    assert_eq!(recovered.unknown_since, Some(NOW + 99));
    assert_eq!(recovered.usage, None);
    assert_eq!(recovered.admission.reserved_micros, 2);
    assert_eq!(
        service.release_unknown(NOW + 100, 0).await,
        Err(ExecutionError::Conflict)
    );
    fixture.advance(86_399);
    assert_eq!(service.maintain_executions().await.unwrap(), 0);
    fixture.advance(1);
    assert_eq!(service.maintain_executions().await.unwrap(), 1);
    assert_eq!(
        service.snapshot("interrupted").await.unwrap().state,
        State::ClosedUnknown
    );
    service
        .reconcile("interrupted", evidence(1, 3, false))
        .await
        .unwrap();
    assert_eq!(
        service.snapshot("interrupted").await.unwrap().state,
        State::ClosedUnknown
    );
    service
        .reconcile("interrupted", evidence(2, 7, true))
        .await
        .unwrap();
    assert_eq!(
        service.snapshot("interrupted").await.unwrap().state,
        State::Settled
    );
    let audit: String = db.query_row(
        "SELECT json_extract(record_json,'$.reason') FROM maintenance_events WHERE action='release_unknown'",
        [], |row| row.get(0),
    ).unwrap();
    assert_eq!(audit, "reconciliation_expired");
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn retention_pauses_under_pressure_and_rolls_back_on_delete_failure() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(2, 8).await;
    let mut turn = service
        .admit(request(&service, "old-detail", SECRET).await)
        .await
        .unwrap();
    turn.begin_dispatch().unwrap();
    turn.bind(&[object("old-response")]).await.unwrap();
    turn.observe(evidence(1, 5, true)).unwrap();
    turn.finish(Some(Outcome::new(None, NOW))).unwrap();
    assert_eq!(
        service.snapshot("old-detail").await.unwrap().state,
        State::Settled
    );

    let db = fixture.raw();
    db.execute(
        "UPDATE attempts SET created_at_epoch=?1",
        [NOW - 91 * 86400],
    )
    .unwrap();
    db.execute("UPDATE bindings SET expires_at_epoch=?1", [NOW])
        .unwrap();
    let mut continuation = request(&service, "expired-continuation", SECRET).await;
    continuation.references.push(object("old-response"));
    assert_eq!(
        service.admit(continuation).await.err(),
        Some(ExecutionError::UnknownObject)
    );
    db.execute_batch(
        "CREATE TABLE synthetic_pages(payload BLOB);
         INSERT INTO synthetic_pages VALUES(zeroblob(1048576));
         DROP TABLE synthetic_pages;",
    )
    .unwrap();
    let counts = || {
        db.query_row(
            "SELECT (SELECT COUNT(*) FROM attempts), (SELECT COUNT(*) FROM evidence),
                    (SELECT COUNT(*) FROM bindings), (SELECT COUNT(*) FROM usage_daily)",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        )
        .unwrap()
    };
    let pages = || {
        db.pragma_query_value(None, "page_count", |row| row.get::<_, i64>(0))
            .unwrap()
    };
    let original_pages = pages();
    let reserve = fixture
        .db
        .with_file_name("synthetic.sqlite.settlement-reserve");
    std::fs::OpenOptions::new()
        .write(true)
        .open(reserve)
        .unwrap()
        .set_len(0)
        .unwrap();
    assert_eq!(
        service.maintain_executions().await,
        Err(ExecutionError::StoragePressure)
    );
    assert_eq!(counts(), (1, 1, 1, 0));
    assert_eq!(pages(), original_pages);
    service.maintain_storage().await.unwrap();
    assert_eq!(service.storage_pressure(), StoragePressure::Normal);

    db.execute_batch(
        "CREATE TRIGGER synthetic_delete_fault BEFORE DELETE ON attempts
         BEGIN SELECT RAISE(ABORT,'synthetic retention failure'); END;",
    )
    .unwrap();
    assert_eq!(
        service.maintain_executions().await,
        Err(ExecutionError::StorageUnavailable)
    );
    assert_eq!(counts(), (1, 1, 1, 0));
    assert_eq!(pages(), original_pages);
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
    db.execute_batch("DROP TRIGGER synthetic_delete_fault")
        .unwrap();

    let reopened = fixture.open(2, 8).await;
    assert_eq!(reopened.maintain_executions().await.unwrap(), 0);
    assert_eq!(counts(), (0, 0, 0, 1));
    assert_eq!(original_pages - pages(), 32);
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn manual_release_preserves_late_evidence_across_restart() {
    let fixture = Fixture::new(Some(1), None);
    let service = fixture.open(2, 0).await;
    let mut turn = service
        .admit(request(&service, "manual-release", SECRET).await)
        .await
        .unwrap();
    let db = fixture.raw();
    db.execute(
        "UPDATE attempts SET created_at_epoch=?1 WHERE id='manual-release'",
        [NOW - 91 * 86400],
    )
    .unwrap();
    assert_eq!(service.maintain_executions().await.unwrap(), 0);
    assert_eq!(
        service.snapshot("manual-release").await.unwrap().state,
        State::Intent
    );
    db.execute(
        "UPDATE attempts SET created_at_epoch=?1 WHERE id='manual-release'",
        [NOW],
    )
    .unwrap();
    turn.begin_dispatch().unwrap();
    turn.observe(evidence(1, 5, false)).unwrap();
    turn.cancel(NOW).unwrap();
    assert_eq!(
        service.snapshot("manual-release").await.unwrap().state,
        State::Unknown
    );
    assert_eq!(
        service.release_unknown(NOW, 1).await,
        Err(ExecutionError::Conflict)
    );
    db.execute_batch(
        "CREATE TRIGGER synthetic_audit_fault BEFORE INSERT ON maintenance_events
         WHEN NEW.action='release_unknown'
         BEGIN SELECT RAISE(ABORT,'synthetic audit failure'); END;",
    )
    .unwrap();
    assert_eq!(
        service.release_unknown(NOW + 1, 1).await,
        Err(ExecutionError::StorageUnavailable)
    );
    let state: String = db
        .query_row(
            "SELECT state FROM attempts WHERE id='manual-release'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "unknown");
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
    db.execute_batch("DROP TRIGGER synthetic_audit_fault")
        .unwrap();

    let service = fixture.open(2, 0).await;
    assert_eq!(service.release_unknown(NOW + 1, 1).await.unwrap(), 1);
    assert_eq!(
        service.release_unknown(NOW + 1, 1).await,
        Err(ExecutionError::Conflict)
    );
    service.shutdown().await.unwrap();

    let reopened = fixture.open(2, 0).await;
    let closed = reopened.snapshot("manual-release").await.unwrap();
    assert_eq!(closed.state, State::ClosedUnknown);
    assert_eq!(closed.usage.unwrap().input_tokens, 5);
    reopened
        .reconcile("manual-release", evidence(2, 6, false))
        .await
        .unwrap();
    let partial = reopened.snapshot("manual-release").await.unwrap();
    assert_eq!(partial.state, State::ClosedUnknown);
    assert_eq!(partial.usage.unwrap().input_tokens, 6);
    reopened
        .reconcile("manual-release", evidence(3, 7, true))
        .await
        .unwrap();
    let complete = reopened.snapshot("manual-release").await.unwrap();
    assert_eq!(complete.state, State::Settled);
    assert_eq!(complete.usage.unwrap().input_tokens, 7);
    let audits: (i64, String) = db
        .query_row(
            "SELECT COUNT(*),json_extract(MAX(record_json),'$.reason')
         FROM maintenance_events WHERE action='release_unknown'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(audits, (1, "manual".into()));
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn binding_batch_rolls_back_and_cancellation_keeps_observed_usage() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(1, 0).await;
    let db = fixture.raw();
    db.execute_batch(
        "CREATE TRIGGER bind_failure BEFORE INSERT ON bindings WHEN NEW.raw_id='synthetic-fault'
         BEGIN SELECT RAISE(ABORT,'synthetic bind failure'); END;",
    )
    .unwrap();
    let mut turn = service
        .admit(request(&service, "binding", SECRET).await)
        .await
        .unwrap();
    turn.begin_dispatch().unwrap();
    turn.observe(evidence(0, 7, true)).unwrap();
    assert_eq!(
        turn.bind(&[object("response-a"), object("synthetic-fault")])
            .await,
        Err(ExecutionError::StorageUnavailable)
    );
    assert_eq!(
        turn.bind(&[object("response-b")]).await,
        Err(ExecutionError::Conflict)
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM bindings", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    turn.cancel(NOW).unwrap();
    let snapshot = service.snapshot("binding").await.unwrap();
    assert_eq!(snapshot.state, State::Settled);
    assert_eq!(snapshot.usage.unwrap(), evidence(0, 7, true));
    assert_eq!(snapshot.outcome.unwrap().kind, OutcomeKind::Cancelled);
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
}

#[tokio::test]
async fn capacity_and_shutdown_keep_unhanded_leases_recoverable() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(1, 0).await;
    assert_eq!(
        Database::open_existing(&fixture.db).err(),
        Some(DatabaseError::InstanceLocked)
    );
    let mut turn = service
        .admit(request(&service, "active", SECRET).await)
        .await
        .unwrap();
    assert_eq!(service.outstanding(), 1);
    assert_eq!(
        service
            .admit(request(&service, "full", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::Capacity)
    );
    assert_eq!(
        service.snapshot("full").await.err(),
        Some(ExecutionError::UnknownAttempt)
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(30), service.shutdown())
            .await
            .is_err()
    );
    assert_eq!(turn.begin_dispatch(), Err(ExecutionError::Closed));
    service.force_shutdown().await.unwrap();
    assert_eq!(turn.cancel(NOW), Err(ExecutionError::Closed));
    fixture.set_now(NOW + 20);
    let reopened = fixture.open(1, 0).await;
    let recovered = reopened.snapshot("active").await.unwrap();
    assert_eq!(recovered.state, State::Unknown);
    assert_eq!(recovered.unknown_since, Some(NOW + 20));
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn restore_freeze_is_enforced_in_the_admission_transaction() {
    let fixture = Fixture::new(None, None);
    let service = fixture.open(1, 0).await;
    assert!(service.admission_ready().await);
    let db = fixture.raw();
    let id = "00000000-0000-0000-0000-000000000001";
    let mut record = json!({
        "id":id, "backupID":"00000000-0000-0000-0000-000000000002",
        "snapshotUnixSeconds": NOW - 1, "restoredUnixSeconds":NOW,
        "inheritedUnresolvedRequests":0, "inheritedUnresolvedMicros":0,
        "inheritedFreezeUntilUnixSeconds":0, "baselineRevision":0
    });
    let set = |record: &Value| {
        db.execute(
            "UPDATE maintenance_state SET restore_json=?1",
            [record.to_string()],
        )
        .unwrap()
    };
    set(&record);
    assert!(!service.admission_ready().await);
    assert_eq!(
        service
            .admit(request(&service, "unreconciled", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::MaintenanceRequired)
    );
    record["reconciledUnixSeconds"] = json!(NOW);
    record["baselineRevision"] = json!(1);
    record["baseline"] = json!({
        "expectedRevision": 0, "restoreID": id, "auditReference": "synthetic",
        "missingUnresolvedRequests": 0, "missingUnresolvedMicros": 0, "freezeUntilUnixSeconds": NOW + 86_400
    });
    set(&record);
    assert!(!service.admission_ready().await);
    assert_eq!(
        service
            .admit(request(&service, "frozen", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::MaintenanceRequired)
    );
    fixture.advance(86_400);
    assert!(service.admission_ready().await);
    drop(
        service
            .admit(request(&service, "thawed", SECRET).await)
            .await
            .unwrap(),
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn native_image_lower_bound_and_disk_reserve_gate_admission() {
    let fixture = Fixture::new(None, Some(10));
    let service = fixture.open(2, 0).await;
    let mut image = request(&service, "image", SECRET).await;
    image.model = IMAGE_MODEL.into();
    image.requirements = Requirements {
        route: Route::Images,
        vision_input: false,
        image_model: Some(IMAGE_MODEL.into()),
    };
    let mut turn = service.admit(image).await.unwrap();
    turn.begin_dispatch().unwrap();
    assert_eq!(
        turn.observe(evidence(0, 6, false)),
        Err(ExecutionError::InvalidCommand)
    );
    turn.observe(UsageEvidence {
        native_images: Some(true),
        image_input_tokens: Some(11),
        images: 1,
        ..UsageEvidence::default()
    })
    .unwrap();
    turn.cancel(NOW).unwrap();
    assert_eq!(
        service
            .admit(request(&service, "cap", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::KeyLimit)
    );

    let reserve = fixture
        .db
        .with_file_name("synthetic.sqlite.settlement-reserve");
    std::fs::OpenOptions::new()
        .write(true)
        .open(reserve)
        .unwrap()
        .set_len(0)
        .unwrap();
    assert!(!service.admission_ready().await);
    let available_key = request(&service, "pressure", SECOND).await;
    assert_eq!(
        service.admit(available_key.clone()).await.err(),
        Some(ExecutionError::StoragePressure)
    );
    assert_eq!(
        service.snapshot("pressure").await.err(),
        Some(ExecutionError::UnknownAttempt)
    );
    service.maintain_storage().await.unwrap();
    assert!(service.admission_ready().await);
    drop(service.admit(available_key).await.unwrap());
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn transferring_the_database_keeps_the_instance_locked_until_shutdown() {
    let fixture = Fixture::new(None, None);
    let database = Database::open_or_create(&fixture.db).unwrap();
    let (entered, ready_to_check) = tokio::sync::oneshot::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let ready_hook = std::sync::Mutex::new(Some((entered, wait)));
    let opening = tokio::spawn(ExecutionService::open_database(
        database,
        Options::new(ACCOUNT).with_clock(move || {
            if let Some((entered, wait)) = ready_hook.lock().unwrap().take() {
                entered.send(()).unwrap();
                wait.recv_timeout(Duration::from_secs(3)).unwrap();
            }
            NOW
        }),
    ));
    ready_to_check.await.unwrap();
    assert_eq!(
        Database::migrate(&fixture.db),
        Err(DatabaseError::InstanceLocked)
    );
    release.send(()).unwrap();
    let service = opening.await.unwrap().unwrap();
    assert_eq!(
        Database::migrate(&fixture.db),
        Err(DatabaseError::InstanceLocked)
    );
    service.shutdown().await.unwrap();
    Database::migrate(&fixture.db).unwrap();
}

#[tokio::test]
async fn cancelling_admission_while_committing_hands_off_the_undelivered_lease() {
    let fixture = Fixture::new(None, None);
    let hook = Arc::new(std::sync::Mutex::new(
        None::<(
            tokio::sync::oneshot::Sender<()>,
            std::sync::mpsc::Receiver<()>,
        )>,
    ));
    let worker_hook = hook.clone();
    let service = ExecutionService::open(
        &fixture.db,
        Options::new(ACCOUNT)
            .with_finalization_capacity(1)
            .with_clock(move || {
                if let Some((signal, release)) = worker_hook.lock().unwrap().take() {
                    signal.send(()).unwrap();
                    release.recv_timeout(Duration::from_secs(2)).unwrap();
                }
                NOW
            }),
    )
    .await
    .unwrap();
    let request = request(&service, "detached", SECRET).await;
    let (signal, reached_transaction) = tokio::sync::oneshot::channel();
    let (release, wait) = std::sync::mpsc::channel();
    *hook.lock().unwrap() = Some((signal, wait));
    let task = {
        let service = service.clone();
        tokio::spawn(async move { service.admit(request).await })
    };
    reached_transaction.await.unwrap();
    let mut probes = Vec::new();
    // The blocked admission occupies one of the 16 regular command slots.
    for _ in 0..15 {
        let mut probe = Box::pin(service.admission_ready());
        assert!(
            std::future::poll_fn(|cx| std::task::Poll::Ready(probe.as_mut().poll(cx)))
                .await
                .is_pending()
        );
        // Keep ownership of the queued command until the queue-full probe completes.
        probes.push(probe);
    }
    assert!(
        !tokio::time::timeout(Duration::from_millis(100), service.admission_ready())
            .await
            .unwrap()
    );
    assert_eq!(service.status(), ExecutionStatus::Accepting);
    drop(probes);
    task.abort();
    assert!(task.await.err().unwrap().is_cancelled());
    release.send(()).unwrap();

    // Graceful shutdown completes only after the orphaned lease's handoff releases its ticket.
    tokio::time::timeout(Duration::from_secs(2), service.shutdown())
        .await
        .unwrap()
        .unwrap();
    let raw = fixture.raw();
    let (state, unknown_since): (String, i64) = raw
        .query_row(
            "SELECT state,unknown_since_epoch FROM attempts WHERE id='detached'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((state.as_str(), unknown_since), ("unknown", NOW));
}

#[tokio::test]
async fn pool_dispatch_uses_both_accounts_and_enforces_key_and_hard_ownership() {
    let fixture = Fixture::new(Some(2), Some(7));
    let cipher = synthetic_cipher();
    fixture.configure_pool(&cipher);
    let service = fixture.open_pool(4).await;
    let key = service
        .authenticate(&[&format!("Bearer {SECRET}")])
        .await
        .unwrap();
    let preferred = AccountIdentity {
        id: ACCOUNT.into(),
        namespace: NAMESPACE.into(),
    };
    let routing = PoolRouting {
        preferred: Some(preferred.clone()),
        ..PoolRouting::default()
    };
    let first_request = operation("pool-first", key.clone());
    let (mut first, work) = admit_pool(&service, &first_request, &cipher, routing)
        .await
        .unwrap();
    assert_eq!(first.admission().owner.identity, ACCOUNT);
    assert_eq!(work.access_token(), format!("access-{ACCOUNT}"));
    first.begin_dispatch().unwrap();
    let reference = object("resp_pool_bound");
    first.bind(std::slice::from_ref(&reference)).await.unwrap();

    let second_request = operation("pool-second", key.clone());
    let (second, work) = admit_pool(&service, &second_request, &cipher, PoolRouting::default())
        .await
        .unwrap();
    assert_eq!(second.admission().owner.identity, OTHER_ACCOUNT);
    assert_eq!(work.access_token(), format!("access-{OTHER_ACCOUNT}"));

    let denied = operation("pool-key-limit", key.clone());
    assert_eq!(
        admit_pool(&service, &denied, &cipher, PoolRouting::default())
            .await
            .err(),
        Some(ExecutionError::KeyLimit)
    );
    assert_eq!(
        service.snapshot(&denied.attempt).await.err(),
        Some(ExecutionError::UnknownAttempt)
    );

    first.observe(evidence(0, 7, true)).unwrap();
    first.finish(Some(Outcome::new(None, NOW))).unwrap();
    drop(second);
    assert_eq!(
        service
            .snapshot(&first_request.attempt)
            .await
            .unwrap()
            .state,
        State::Settled
    );
    assert_eq!(
        admit_pool(&service, &denied, &cipher, PoolRouting::default())
            .await
            .err(),
        Some(ExecutionError::KeyLimit)
    );

    let next_key = service
        .authenticate(&[&format!("Bearer {SECOND}")])
        .await
        .unwrap();
    assert_eq!(
        service
            .pool_hint(&next_key, std::slice::from_ref(&reference))
            .await
            .unwrap(),
        Some(preferred.clone())
    );
    let mut next = operation("pool-continue", next_key.clone());
    next.references.push(reference.clone());
    let db = fixture.raw();
    db.execute("UPDATE accounts SET mode='draining' WHERE id=?1", [ACCOUNT])
        .unwrap();
    db.execute(
        "UPDATE model_directory_routes SET account=?1",
        [OTHER_ACCOUNT],
    )
    .unwrap();
    let prefer_other = PoolRouting {
        preferred: Some(AccountIdentity {
            id: OTHER_ACCOUNT.into(),
            namespace: OTHER_NAMESPACE.into(),
        }),
        ..PoolRouting::default()
    };
    assert_eq!(
        admit_pool(&service, &next, &cipher, prefer_other.clone())
            .await
            .err(),
        Some(ExecutionError::AccountUnavailable),
    );
    db.execute("UPDATE model_directory_routes SET account=NULL", [])
        .unwrap();
    fixture.advance(10);
    let (continuation, work) = admit_pool(&service, &next, &cipher, prefer_other)
        .await
        .unwrap();
    assert_eq!(continuation.admission().owner.identity, ACCOUNT);
    assert_eq!(work.access_token(), format!("access-{ACCOUNT}"));
    assert!(
        continuation
            .admission()
            .account_snapshot
            .as_ref()
            .unwrap()
            .continuation
    );
    let expiry: i64 = db
        .query_row(
            "SELECT expires_at_epoch FROM bindings WHERE raw_id=?1",
            [&reference.raw_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(expiry, NOW + 10 + 30 * 86_400);
    drop(continuation);
    let required = PoolRouting {
        required: Some(preferred),
        ..PoolRouting::default()
    };
    assert_eq!(
        admit_pool(
            &service,
            &operation("pool-turn-state", next_key),
            &cipher,
            required
        )
        .await
        .err(),
        Some(ExecutionError::AccountUnavailable)
    );

    let foreign = service
        .authenticate(&[&format!("Bearer {FOREIGN}")])
        .await
        .unwrap();
    let mut request = operation("pool-foreign", foreign);
    request.references.push(reference);
    assert_eq!(
        admit_pool(&service, &request, &cipher, PoolRouting::default())
            .await
            .err(),
        Some(ExecutionError::UnknownObject)
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn pool_writer_rechecks_policy_and_snapshot_after_preparation() {
    let fixture = Fixture::new(None, None);
    let cipher = synthetic_cipher();
    fixture.configure_pool(&cipher);
    let service = fixture.open_pool(2).await;
    let key = service
        .authenticate(&[&format!("Bearer {SECRET}")])
        .await
        .unwrap();
    let request = operation("pool-snapshot-race", key.clone());
    let (execution, _) = service
        .admit_pool(request.clone(), || async {
            let prepared =
                prepare_pool(&service, &request, &cipher, PoolRouting::default()).await?;
            assert_eq!(prepared.candidates.len(), 2);
            fixture
                .raw()
                .execute("UPDATE accounts SET revision=2 WHERE id=?1", [ACCOUNT])
                .unwrap();
            Ok(prepared)
        })
        .await
        .unwrap();
    assert_eq!(execution.admission().owner.identity, OTHER_ACCOUNT);
    drop(execution);

    let request = operation("pool-catalog-race", key);
    let (execution, _) = service
        .admit_pool(request.clone(), || async {
            let routing = PoolRouting {
                preferred: Some(AccountIdentity {
                    id: OTHER_ACCOUNT.into(),
                    namespace: OTHER_NAMESPACE.into(),
                }),
                ..PoolRouting::default()
            };
            let prepared = prepare_pool(&service, &request, &cipher, routing).await?;
            assert_eq!(prepared.candidates.len(), 2);
            fixture
                .raw()
                .execute("UPDATE model_directory_routes SET account=?1", [ACCOUNT])
                .unwrap();
            Ok(prepared)
        })
        .await
        .unwrap();
    assert_eq!(execution.admission().owner.identity, ACCOUNT);
    drop(execution);
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn pool_binding_renewal_failure_rolls_back_intent_and_concurrency() {
    let fixture = Fixture::new(None, None);
    let cipher = synthetic_cipher();
    fixture.configure_pool(&cipher);
    let service = fixture.open_pool(2).await;
    let key = service
        .authenticate(&[&format!("Bearer {SECRET}")])
        .await
        .unwrap();
    let reference = object("resp_pool_rollback");
    let (mut first, _) = admit_pool(
        &service,
        &operation("pool-source", key.clone()),
        &cipher,
        PoolRouting::default(),
    )
    .await
    .unwrap();
    first.begin_dispatch().unwrap();
    first.bind(std::slice::from_ref(&reference)).await.unwrap();
    drop(first);
    service.snapshot("pool-source").await.unwrap();

    let db = fixture.raw();
    db.execute_batch(
        "CREATE TRIGGER pool_binding_failure BEFORE UPDATE OF expires_at_epoch ON bindings
         BEGIN SELECT RAISE(ABORT,'synthetic bind renewal failure'); END;",
    )
    .unwrap();
    let mut next = operation("pool-rollback", key);
    next.references.push(reference);
    fixture.advance(10);
    assert_eq!(
        admit_pool(&service, &next, &cipher, PoolRouting::default())
            .await
            .err(),
        Some(ExecutionError::StorageUnavailable)
    );
    assert_eq!(
        service.snapshot(&next.attempt).await.err(),
        Some(ExecutionError::UnknownAttempt)
    );
    let (expiry, peaks): (i64, i64) = db
        .query_row(
            "SELECT expires_at_epoch,(SELECT COUNT(*) FROM account_concurrency WHERE at_epoch>?1)
         FROM bindings WHERE raw_id='resp_pool_rollback'",
            [NOW],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((expiry, peaks), (NOW + 30 * 86_400, 0));
    assert_eq!(
        service.shutdown().await,
        Err(ExecutionError::StorageUnavailable)
    );
}

async fn wait_until_paced<T>(
    service: &ExecutionService,
    mut admission: Pin<&mut impl Future<Output = T>>,
) {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            tokio::select! {
                biased;
                _ = &mut admission => panic!("pool admission did not wait"),
                _ = tokio::time::sleep(Duration::from_millis(1)) => {}
            }
            if service.outstanding() == 0 {
                break;
            }
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn pacing_releases_ticket_while_cancelled_or_repreparing_and_restores_cooldown() {
    let fixture = Fixture::new(None, None);
    let cipher = synthetic_cipher();
    fixture.configure_pool(&cipher);
    let service = fixture.open_pool(1).await;
    service
        .configure_health_models(vec![MODEL.into()])
        .await
        .unwrap();
    let key = service
        .authenticate(&[&format!("Bearer {SECRET}")])
        .await
        .unwrap();
    let preferred = AccountIdentity {
        id: ACCOUNT.into(),
        namespace: NAMESPACE.into(),
    };
    let routing = PoolRouting {
        preferred: Some(preferred.clone()),
        ..PoolRouting::default()
    };
    let operation_for = |id: &str| operation(id, key.clone());

    let (mut first, _) = admit_pool(
        &service,
        &operation_for("pool-overload"),
        &cipher,
        routing.clone(),
    )
    .await
    .unwrap();
    first.begin_dispatch().unwrap();
    first
        .finish(Some(Outcome::new(Some(Failure::UpstreamUnavailable), NOW)))
        .unwrap();
    service.snapshot("pool-overload").await.unwrap();

    let cancelled = operation_for("pool-cancelled-wait");
    let mut wait = Box::pin(admit_pool(&service, &cancelled, &cipher, routing.clone()));
    wait_until_paced(&service, wait.as_mut()).await;
    drop(wait);
    assert_eq!(
        service.snapshot(&cancelled.attempt).await.err(),
        Some(ExecutionError::UnknownAttempt)
    );

    let retried = operation_for("pool-reprepared");
    let mut preparations = 0;
    let mut retry = Box::pin(service.admit_pool(retried.clone(), || {
        preparations += 1;
        prepare_pool(&service, &retried, &cipher, routing.clone())
    }));
    wait_until_paced(&service, retry.as_mut()).await;
    let db = fixture.raw();
    db.execute("UPDATE accounts SET mode='disabled' WHERE id=?1", [ACCOUNT])
        .unwrap();
    fixture.advance(1);
    let (mut retry_execution, work) = tokio::time::timeout(Duration::from_secs(3), &mut retry)
        .await
        .unwrap()
        .unwrap();
    drop(retry);
    assert_eq!(preparations, 2);
    assert_eq!(work.access_token(), format!("access-{OTHER_ACCOUNT}"));

    retry_execution.begin_dispatch().unwrap();
    let mut outcome = Outcome::new(Some(Failure::UpstreamUnavailable), NOW + 1);
    outcome.cooldown_seconds = Some(22);
    retry_execution.finish(Some(outcome)).unwrap();
    service.shutdown().await.unwrap();

    let service = fixture.open_pool(1).await;
    let restart = operation_for("pool-cooldown-on-restart");
    assert_eq!(
        admit_pool(&service, &restart, &cipher, PoolRouting::default())
            .await
            .err(),
        Some(ExecutionError::AccountCooldown {
            retry_after_seconds: 22
        })
    );
    assert_eq!(
        service.snapshot(&restart.attempt).await.err(),
        Some(ExecutionError::UnknownAttempt)
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn directory_update_between_preparation_and_admission_does_not_create_intent() {
    let fixture = Fixture::new(None, None);
    let cipher = synthetic_cipher();
    fixture.configure_pool(&cipher);
    let service = fixture.open_pool(4).await;
    let key = service
        .authenticate(&[&format!("Bearer {SECRET}")])
        .await
        .unwrap();
    let request = operation("stale-directory", key);
    let result = service
        .admit_pool(request.clone(), || async {
            let prepared = prepare_pool(&service, &request, &cipher, PoolRouting {
                catalog_revision: Some(1),
                ..PoolRouting::default()
            }).await?;
            service.governance_command(codexone_execution::GovernanceWork::Optional, |db, _, _| {
                db.connection().execute(
                    "UPDATE model_directory SET revision=2 WHERE singleton=1 AND revision=1",
                    [],
                ).unwrap();
            }).await?;
            Ok(prepared)
        })
        .await;
    assert!(matches!(result, Err(ExecutionError::Conflict)));
    assert!(matches!(
        service.snapshot("stale-directory").await,
        Err(ExecutionError::UnknownAttempt)
    ));
    assert_eq!(service.outstanding(), 0);
    service.shutdown().await.unwrap();
}
