use std::{
    num::NonZeroU16,
    sync::{
        Arc,
        atomic::{AtomicI64, Ordering},
    },
    time::Duration,
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use codexone_execution::{Execution, ExecutionService, Options, Outcome};
use codexone_governance::{AccountMode, Error, Governance, Target, Work, Writer};
use codexone_http_upstream::{CancellationToken, Instant};
use codexone_identity_runtime::{IdentityRuntime, SubscriptionProvider};
use codexone_quota_jobs::{
    PrimingModel, PrimingRequest, PrimingSettings, PrimingSupervisor, PrimingTransport, ResetCode,
    ResetSettings, ResetSupervisor,
};
use codexone_storage::AccountCredentialCipher;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::mpsc,
};

const NOW: i64 = 1_700_000_000;
const WAIT: Duration = Duration::from_secs(4);
const CLIENT: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const NONCE: &str = "synthetic_nonce_0123456789012345678";

#[derive(Clone)]
struct TestWriter(ExecutionService);

impl Writer for TestWriter {
    async fn run<T: Send + 'static>(
        &self,
        work: Work,
        operation: impl FnOnce(
            &mut codexone_storage::Database,
            i64,
            bool,
        ) -> codexone_governance::Result<T>
        + Send
        + 'static,
    ) -> codexone_governance::Result<T> {
        use codexone_execution::GovernanceWork as G;
        let work = match work {
            Work::Read => G::Read,
            Work::Optional => G::Optional,
            Work::Restrict => G::Restrict,
            Work::Admission => G::Admission,
            Work::Critical => G::Critical,
        };
        self.0
            .governance_command(work, operation)
            .await
            .map_err(|_| Error::Unavailable)?
    }
}

struct Fixture {
    dir: tempfile::TempDir,
    execution: ExecutionService,
    governance: Arc<Governance<TestWriter>>,
    identity: IdentityRuntime<TestWriter>,
    clock: Arc<AtomicI64>,
    account: String,
    quota: TcpListener,
}

fn cipher() -> AccountCredentialCipher {
    AccountCredentialCipher::from_hex(&"77".repeat(32), &[]).unwrap()
}

fn jwt(nonce: Option<&str>) -> String {
    let mut claims = json!({
        "iss": "https://auth.openai.com", "aud": CLIENT, "sub": "synthetic-subject",
        "exp": NOW + 7200,
        "https://api.openai.com/auth": {"chatgpt_account_id": "synthetic-account"}
    });
    if let Some(nonce) = nonce {
        claims["nonce"] = nonce.into();
    }
    format!(
        "{}.{}.{}",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256"}"#),
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap()),
        URL_SAFE_NO_PAD.encode(b"synthetic")
    )
}

impl Fixture {
    async fn open() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("swift-v19.sqlite");
        let seed = rusqlite::Connection::open(&db).unwrap();
        seed.execute_batch(include_str!("../../execution/tests/swift_v19.sql"))
            .unwrap();
        seed.execute("INSERT INTO metadata VALUES(1,'{}')", [])
            .unwrap();
        drop(seed);
        let clock = Arc::new(AtomicI64::new(NOW));
        let captured = clock.clone();
        let execution = ExecutionService::open(
            &db,
            Options::for_account_pool().with_clock(move || captured.load(Ordering::Relaxed)),
        )
        .await
        .unwrap();
        let governance = Arc::new(Governance::new(
            TestWriter(execution.clone()),
            Some(cipher()),
        ));
        let auth = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let quota = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let configured_port =
            |l: &TcpListener| NonZeroU16::new(l.local_addr().unwrap().port()).unwrap();
        let captured = clock.clone();
        let provider = SubscriptionProvider::synthetic_loopback(
            configured_port(&auth),
            configured_port(&quota),
            move || captured.load(Ordering::Relaxed),
        );
        use codexone_governance::AuthorizationProvider;
        let authorize = provider.authorize(
            "synthetic-code",
            "synthetic_verifier_01234567890123456789012345678",
            NONCE,
        );
        let upstream = async {
            let (mut socket, head, _) = request(&auth).await;
            assert!(head.starts_with("POST /oauth/token "));
            respond(
                &mut socket,
                json!({
                    "access_token": jwt(None), "id_token": jwt(Some(NONCE)),
                    "refresh_token": "synthetic-refresh", "token_type": "Bearer"
                }),
            )
            .await;
        };
        let (verified, ()) = tokio::join!(authorize, upstream);
        let account = governance
            .seal_verified(Target::Create, verified.unwrap())
            .await
            .unwrap();
        let account = governance
            .set_account_mode(account.id, account.revision, AccountMode::Enabled)
            .await
            .unwrap()
            .id;
        let identity = IdentityRuntime::new(
            TestWriter(execution.clone()),
            governance.clone(),
            cipher(),
            provider,
        );
        Self {
            dir,
            execution,
            governance,
            identity,
            clock,
            account,
            quota,
        }
    }

    async fn observe(&self, used: i64, remaining: i64) {
        let observation = self.identity.observe_account(&self.account);
        let upstream = async {
            let (mut socket, head, _) = request(&self.quota).await;
            assert!(head.starts_with("GET /backend-api/wham/usage "));
            let now = self.clock.load(Ordering::Relaxed);
            respond(
                &mut socket,
                json!({"rate_limit": {
                    "allowed": true, "limit_reached": false, "primary_window": {
                        "limit_window_seconds": 18000, "used_percent": used,
                        "reset_at": now + remaining, "reset_after_seconds": remaining
                    }
                }}),
            )
            .await;
        };
        let (result, ()) = tokio::join!(observation, upstream);
        assert!(result.unwrap().failure.is_none());
    }

    async fn scalar<T: rusqlite::types::FromSql + Send + 'static>(&self, sql: &'static str) -> T {
        TestWriter(self.execution.clone())
            .run(Work::Read, |db, _, _| {
                Ok(db.connection().query_row(sql, [], |row| row.get(0))?)
            })
            .await
            .unwrap()
    }
}

async fn request(listener: &TcpListener) -> (TcpStream, String, Value) {
    tokio::time::timeout(WAIT, async {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let end = loop {
            assert_ne!(socket.read_buf(&mut bytes).await.unwrap(), 0);
            if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                break end + 4;
            }
            assert!(bytes.len() < 65536);
        };
        let head = String::from_utf8(bytes[..end].to_vec()).unwrap();
        let len = head
            .lines()
            .find_map(|line| line.strip_prefix("content-length: "))
            .unwrap_or("0")
            .parse::<usize>()
            .unwrap();
        while bytes.len() < end + len {
            assert_ne!(socket.read_buf(&mut bytes).await.unwrap(), 0);
        }
        let body = serde_json::from_slice(&bytes[end..end + len]).unwrap_or_default();
        (socket, head, body)
    })
    .await
    .unwrap()
}

async fn respond(socket: &mut TcpStream, body: Value) {
    let body = body.to_string();
    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
    socket.shutdown().await.unwrap();
}

#[tokio::test]
async fn reset_recovers_original_identity_after_a_lost_response() {
    let f = Fixture::open().await;
    let clock = f.clock.clone();
    let reset = ResetSupervisor::new(
        TestWriter(f.execution.clone()),
        f.governance.clone(),
        f.identity.clone(),
        move || clock.load(Ordering::Relaxed) as f64,
    );
    let listing = reset.list(&f.account);
    let upstream = async {
        let (mut socket, head, _) = request(&f.quota).await;
        assert!(head.starts_with("GET /backend-api/wham/rate-limit-reset-credits "));
        respond(&mut socket, json!({"available_count": 1, "credits":[{
            "id": "synthetic-card", "reset_type": "quota", "status": "available", "granted_at": "2023-11-14T21:00:00Z"
        }]})).await;
    };
    let (list, ()) = tokio::join!(listing, upstream);
    assert_eq!(list.unwrap().available_count, 1);

    let use_card = reset.consume(&f.account, Some("synthetic-card".into()));
    let lose_reply = async {
        let (_socket, head, body) = request(&f.quota).await;
        assert!(head.starts_with("POST /backend-api/wham/rate-limit-reset-credits/consume "));
        assert_eq!(body["credit_id"], "synthetic-card");
        assert_eq!(
            f.scalar::<String>("SELECT code FROM reset_credit_events")
                .await,
            "unknown"
        );
        body
    };
    let (result, original) = tokio::join!(use_card, lose_reply);
    assert_eq!(result.unwrap().code, ResetCode::Unknown);
    reset.shutdown().await;
    f.identity.shutdown().await;
    f.execution.shutdown().await.unwrap();

    let service = ExecutionService::open(
        f.dir.path().join("swift-v19.sqlite"),
        Options::for_account_pool().with_clock(|| NOW),
    )
    .await
    .unwrap();
    let governance = Arc::new(Governance::new(TestWriter(service.clone()), Some(cipher())));
    let identity = IdentityRuntime::new(
        TestWriter(service.clone()),
        governance.clone(),
        cipher(),
        f.identity.subscription_provider().clone(),
    );
    let reset = ResetSupervisor::new(
        TestWriter(service.clone()),
        governance,
        identity.clone(),
        || NOW as f64,
    );
    let status = reset.status(&f.account).await.unwrap();
    assert!(status.pending);
    let stale = reset
        .set_settings(&f.account, status.revision - 1, ResetSettings::default())
        .await;
    assert!(matches!(stale, Err(Error::AccountConflict)));
    assert!(matches!(
        reset.consume(&f.account, Some("other-card".into())).await,
        Err(Error::AccountConflict)
    ));
    let reconcile = reset.consume(&f.account, None);
    let upstream = async {
        let (mut socket, _, body) = request(&f.quota).await;
        assert_eq!(body, original);
        respond(
            &mut socket,
            json!({"code":"already_redeemed","windows_reset":0}),
        )
        .await;
    };
    let (result, ()) = tokio::join!(reconcile, upstream);
    assert_eq!(result.unwrap().code, ResetCode::AlreadyRedeemed);
    assert!(!reset.status(&f.account).await.unwrap().pending);
    let count = TestWriter(service.clone())
        .run(Work::Read, |db, _, _| {
            Ok(db.connection().query_row(
                "SELECT COUNT(*) FROM reset_credit_events WHERE credit_hash IS NOT NULL",
                [],
                |row| row.get::<_, i64>(0),
            )?)
        })
        .await
        .unwrap();
    assert_eq!(count, 2);
    reset.shutdown().await;
    identity.shutdown().await;
    service.shutdown().await.unwrap();
}

struct PrimingProbe {
    count: mpsc::Sender<String>,
    clock: Arc<AtomicI64>,
}

impl PrimingTransport for PrimingProbe {
    async fn exchange(
        &self,
        request: PrimingRequest,
        lease: &mut Execution,
        _stop: CancellationToken,
        _deadline: Instant,
    ) -> Option<Outcome> {
        assert_eq!(request.body["input"], "hello");
        assert_eq!(request.body["store"], false);
        assert_eq!(request.body["tools"], json!([]));
        assert_eq!(request.body["reasoning"]["effort"], "minimal");
        assert!(request.body.get("max_output_tokens").is_none());
        assert!(!request.headers["authorization"].is_empty());
        self.count
            .send(lease.admission().attempt.clone())
            .await
            .unwrap();
        (self.clock.load(Ordering::Relaxed) != NOW).then(|| Outcome::new(None, NOW + 7201))
    }
}

fn catalog() -> Vec<PrimingModel> {
    vec![PrimingModel {
        catalog_revision: None,
        account: None,
        id: "synthetic-model".into(),
        input_micros_per_million: 1,
        output_micros_per_million: 1,
        reasoning_efforts: vec!["low".into(), "minimal".into()],
        supports_verbosity: true,
    }]
}

#[tokio::test]
async fn priming_unknown_and_moving_idle_reset_share_one_durable_barrier() {
    let f = Fixture::open().await;
    f.observe(0, 18000).await;
    let (send, mut receive) = mpsc::channel(2);
    let probe = PrimingProbe {
        count: send,
        clock: f.clock.clone(),
    };
    let (priming, signals, worker) = PrimingSupervisor::new(
        TestWriter(f.execution.clone()),
        f.governance.clone(),
        f.identity.clone(),
        f.execution.clone(),
        probe,
        0,
        catalog,
    );
    let status = priming.status(&f.account).await.unwrap();
    let settings = PrimingSettings {
        enabled: true,
        ..PrimingSettings::default()
    };
    priming
        .set_settings(&f.account, status.revision, settings)
        .await
        .unwrap();
    let worker = tokio::spawn(worker.run());
    let attempt = tokio::time::timeout(WAIT, receive.recv())
        .await
        .unwrap()
        .unwrap();
    let status = priming.status(&f.account).await.unwrap();
    assert_eq!(status.last_result.as_deref(), Some("unknown"));
    assert_eq!(
        f.execution.snapshot(&attempt).await.unwrap().state,
        codexone_execution::State::Unknown
    );
    // An idle observation moves the reported reset but cannot release the barrier.
    f.clock.store(NOW + 60, Ordering::Relaxed);
    f.observe(0, 18000).await;
    signals.observed_quota(&f.account);
    assert!(
        tokio::time::timeout(Duration::from_millis(150), receive.recv())
            .await
            .is_err()
    );
    let count: i64 = f.scalar("SELECT COUNT(*) FROM quota_priming_events").await;
    assert_eq!(count, 1);

    signals.stop();
    worker.await.unwrap().unwrap();
    f.identity.shutdown().await;
    f.execution.shutdown().await.unwrap();
    let reopened = ExecutionService::open(
        f.dir.path().join("swift-v19.sqlite"),
        Options::for_account_pool().with_clock(|| NOW + 60),
    )
    .await
    .unwrap();
    assert_eq!(
        reopened.snapshot(&attempt).await.unwrap().state,
        codexone_execution::State::Unknown
    );
    let value = TestWriter(reopened.clone()).run(Work::Read, |db, _, _| Ok(db.connection().query_row(
        "SELECT json_extract(record_json,'$.windows.five_hour.awaitingActive') FROM account_quota_priming",
        [], |row| row.get::<_, bool>(0))?)).await.unwrap();
    assert!(value);
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn interrupted_priming_finalization_recovers_pending_audit_without_releasing_window() {
    use codexone_execution::{AccountDispatch, PrimingAdmission, State};

    let f = Fixture::open().await;
    f.observe(0, 18000).await;
    let (send, _) = mpsc::channel(1);
    let probe = PrimingProbe {
        count: send,
        clock: f.clock.clone(),
    };
    let (priming, signals, _worker) = PrimingSupervisor::new(
        TestWriter(f.execution.clone()),
        f.governance.clone(),
        f.identity.clone(),
        f.execution.clone(),
        probe,
        0,
        catalog,
    );
    let revision = priming.status(&f.account).await.unwrap().revision;
    let settings = PrimingSettings {
        enabled: true,
        ..PrimingSettings::default()
    };
    priming
        .set_settings(&f.account, revision, settings.clone())
        .await
        .unwrap();
    let credential = f
        .identity
        .prepare_dispatch(&f.account, false)
        .await
        .unwrap();
    let mut lease = f
        .execution
        .admit_priming(PrimingAdmission {
            catalog_revision: None,
            attempt: "interrupted-priming".into(),
            account: AccountDispatch::from_subscription(&credential),
            model: "synthetic-model".into(),
            settings,
            reasoning_effort: "low".into(),
            pricing_version: "synthetic-price".into(),
            reserved_micros: 0,
        })
        .await
        .unwrap();
    lease.begin_dispatch().unwrap();
    assert_eq!(
        f.scalar::<String>("SELECT result FROM quota_priming_events")
            .await,
        "pending"
    );
    signals.stop();
    f.identity.shutdown().await;
    f.execution.force_shutdown().await.unwrap();
    drop(lease);

    let service = ExecutionService::open(
        f.dir.path().join("swift-v19.sqlite"),
        Options::for_account_pool().with_clock(|| NOW + 1),
    )
    .await
    .unwrap();
    assert_eq!(
        service.snapshot("interrupted-priming").await.unwrap().state,
        State::Unknown
    );
    let recovered =
        TestWriter(service.clone())
            .run(Work::Read, |db, _, _| {
                Ok(db.connection().query_row(
        "SELECT e.result, json_extract(p.record_json,'$.windows.five_hour.awaitingActive'),
                json_extract(p.record_json,'$.failures')
         FROM quota_priming_events e JOIN account_quota_priming p ON p.account_id=e.account_id",
        [], |row| Ok((row.get::<_,String>(0)?, row.get::<_,bool>(1)?, row.get::<_,i64>(2)?)))?)
            })
            .await
            .unwrap();
    assert_eq!(recovered, ("unknown".into(), true, 1));
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn automatic_reset_learns_expiry_and_reuses_missing_card_only_before_expiry() {
    let f = Fixture::open().await;
    let clock = f.clock.clone();
    let owner = ResetSupervisor::new(
        TestWriter(f.execution.clone()),
        f.governance.clone(),
        f.identity.clone(),
        move || clock.load(Ordering::Relaxed) as f64,
    );
    let revision = owner.status(&f.account).await.unwrap().revision;
    owner
        .set_settings(
            &f.account,
            revision,
            ResetSettings {
                auto_use_before_expiry: true,
                lead_minutes: 5,
                retry_count: 2,
            },
        )
        .await
        .unwrap();
    let scheduler = tokio::spawn({
        let owner = owner.clone();
        async move { owner.run().await }
    });
    let card = || {
        json!({"available_count": 1, "credits":[{
            "id": "synthetic-card", "reset_type": "quota", "status": "available",
            "granted_at": "2023-11-14T21:00:00Z", "expires_at": "2023-11-14T22:20:00Z"
        }]})
    };
    let (mut socket, head, _) = request(&f.quota).await;
    assert!(head.starts_with("GET "));
    // Hold the startup scan's upstream reply while a manual list competes for the account slot.
    assert!(matches!(
        owner.list_with_status(&f.account).await,
        Err(Error::AccountConflict)
    ));
    respond(&mut socket, card()).await;
    tokio::time::timeout(WAIT, async {
        while owner.active_operations() != 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let manual = owner.list_with_status(&f.account);
    let upstream = async {
        let (mut socket, head, _) = request(&f.quota).await;
        assert!(head.starts_with("GET /backend-api/wham/rate-limit-reset-credits "));
        respond(&mut socket, card()).await;
    };
    let (list, ()) = tokio::join!(manual, upstream);
    assert_eq!(list.unwrap().list.credits[0].id, "synthetic-card");
    assert!(
        tokio::time::timeout(Duration::from_millis(100), f.quota.accept())
            .await
            .is_err()
    );

    // The card expires 400 seconds after NOW. Wake at expiry minus the configured lead.
    f.clock.store(NOW + 100, Ordering::Relaxed);
    owner.observed_credits(&f.account);
    let (mut socket, head, _) = request(&f.quota).await;
    assert!(head.starts_with("GET "));
    respond(&mut socket, card()).await;
    let (socket, head, first) = request(&f.quota).await;
    assert!(head.starts_with("POST "));
    drop(socket);
    tokio::time::timeout(WAIT, async {
        while owner.active_operations() != 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    f.clock.store(NOW + 161, Ordering::Relaxed);
    owner.observed_credits(&f.account);
    let (mut socket, head, _) = request(&f.quota).await;
    assert!(head.starts_with("GET "));
    respond(&mut socket, json!({"available_count":0,"credits":[]})).await;
    let (socket, head, retry) = request(&f.quota).await;
    assert!(head.starts_with("POST "));
    assert_eq!(retry, first);
    drop(socket);

    tokio::time::timeout(WAIT, async {
        while owner.active_operations() != 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    f.clock.store(NOW + 400, Ordering::Relaxed);
    owner.observed_credits(&f.account);
    let (mut socket, head, _) = request(&f.quota).await;
    assert!(head.starts_with("GET "));
    respond(&mut socket, json!({"available_count":0,"credits":[]})).await;
    assert!(
        tokio::time::timeout(Duration::from_millis(150), f.quota.accept())
            .await
            .is_err()
    );
    assert!(owner.status(&f.account).await.unwrap().pending);
    assert_eq!(
        f.scalar::<i64>("SELECT COUNT(*) FROM reset_credit_events WHERE action='consume'")
            .await,
        2
    );
    owner.shutdown().await;
    scheduler.await.unwrap().unwrap();
    f.identity.shutdown().await;
    f.execution.shutdown().await.unwrap();
}

#[test]
fn management_dtos_preserve_legacy_lead_and_reject_ambiguous_commands() {
    use codexone_quota_jobs::{PrimingSettingsUpdate, ResetConsume, ResetSettingsUpdate};
    let input = r#"{"revision":2,"autoUseBeforeExpiry":true,"leadHours":2}"#;
    let (revision, settings) = serde_json::from_str::<ResetSettingsUpdate>(input)
        .unwrap()
        .settings()
        .unwrap();
    assert_eq!(
        (revision, settings.lead_minutes, settings.retry_count),
        (2, 120, 3)
    );
    let mixed =
        r#"{"revision":2,"autoUseBeforeExpiry":true,"leadHours":2,"leadMinutes":8,"retryCount":3}"#;
    assert!(serde_json::from_str::<ResetSettingsUpdate>(mixed).is_err());
    let duplicate = r#"{"revision":2,"revision":3,"autoUseBeforeExpiry":true,"leadHours":2}"#;
    assert!(serde_json::from_str::<ResetSettingsUpdate>(duplicate).is_err());
    assert!(serde_json::from_str::<ResetConsume>(r#"{"creditID":null}"#).is_err());
    assert!(serde_json::from_str::<ResetConsume>(r#"{"redeem_request_id":"synthetic"}"#).is_err());
    let missing = r#"{"revision":2,"enabled":true,"message":"hello"}"#;
    assert!(serde_json::from_str::<PrimingSettingsUpdate>(missing).is_err());
    let input = r#"{"revision":2,"enabled":true,"message":"hello","model":null}"#;
    assert!(
        serde_json::from_str::<PrimingSettingsUpdate>(input)
            .unwrap()
            .settings()
            .1
            .model
            .is_none()
    );
}

#[tokio::test]
async fn force_stopping_dispatched_priming_keeps_its_window_barrier() {
    use codexone_execution::{AccountDispatch, PrimingAdmission};

    let f = Fixture::open().await;
    f.observe(0, 18000).await;
    let (send, _) = mpsc::channel(1);
    let (priming, signals, _worker) = PrimingSupervisor::new(
        TestWriter(f.execution.clone()),
        f.governance.clone(),
        f.identity.clone(),
        f.execution.clone(),
        PrimingProbe {
            count: send,
            clock: f.clock.clone(),
        },
        0,
        catalog,
    );
    let settings = PrimingSettings {
        enabled: true,
        ..PrimingSettings::default()
    };
    let revision = priming.status(&f.account).await.unwrap().revision;
    priming
        .set_settings(&f.account, revision, settings.clone())
        .await
        .unwrap();
    let credential = f
        .identity
        .prepare_dispatch(&f.account, false)
        .await
        .unwrap();
    let mut lease = f
        .execution
        .admit_priming(PrimingAdmission {
            catalog_revision: None,
            attempt: "forced-priming".into(),
            account: AccountDispatch::from_subscription(&credential),
            model: "synthetic-model".into(),
            settings,
            reasoning_effort: "low".into(),
            pricing_version: "synthetic-price".into(),
            reserved_micros: 0,
        })
        .await
        .unwrap();
    lease.begin_dispatch().unwrap();
    assert_eq!(f.execution.stop_account_executions(&f.account), 1);
    lease.finish(None).unwrap();
    assert_eq!(
        f.scalar::<String>("SELECT result FROM quota_priming_events")
            .await,
        "client_cancelled"
    );
    assert!(f.scalar::<bool>("SELECT json_extract(record_json,'$.windows.five_hour.awaitingActive') FROM account_quota_priming").await);
    signals.stop();
    f.identity.shutdown().await;
    f.execution.shutdown().await.unwrap();
}
