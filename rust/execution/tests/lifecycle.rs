use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicI64, Ordering},
};
use std::time::Duration;

use codexone_execution::*;
use codexone_storage::{Database, DatabaseError, key_digest};
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
    AdmissionRequest {
        attempt: id.into(),
        request_id: Some(format!("request-{id}")),
        key,
        account: credential.dispatch_snapshot(NOW + 999_999, false),
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
    let admitted = service.admit(continuation).await.unwrap();
    assert_eq!(
        admitted.admission().owner.principal,
        turn.admission().owner.principal
    );
    assert_ne!(admitted.admission().owner.key, turn.admission().owner.key);
    drop(admitted);

    let db = fixture.raw();
    let mut stale = initial;
    stale.attempt = "stale-key".into();
    stale.request_id = None;
    db.execute(
        "UPDATE managed_keys SET metadata_json=json_set(metadata_json,'$.revision',2) WHERE id=?1",
        [stale.key.id()],
    )
    .unwrap();
    assert_eq!(
        service.admit(stale).await.err(),
        Some(ExecutionError::Unauthorized)
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
    turn.finish(Some(Outcome::new(None, NOW))).unwrap();
    let intent = service.snapshot("interrupted").await.unwrap();
    assert_eq!(intent.state, State::Intent);
    assert_eq!(intent.outcome, None);
    assert_eq!(intent.usage, None);
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
    assert_eq!(service.expire_unknown().await.unwrap(), 0);
    fixture.advance(1);
    assert_eq!(service.expire_unknown().await.unwrap(), 1);
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
    assert_eq!(
        service
            .admit(request(&service, "frozen", SECRET).await)
            .await
            .err(),
        Some(ExecutionError::MaintenanceRequired)
    );
    fixture.advance(86_400);
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
    drop(service.admit(available_key).await.unwrap());
    service.shutdown().await.unwrap();
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
