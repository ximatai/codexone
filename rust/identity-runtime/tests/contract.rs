use std::{
    num::NonZeroU16,
    sync::{
        Arc, Mutex,
        atomic::{AtomicI64, Ordering},
    },
    time::Duration,
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use codexone_governance::{
    Account, AccountMode, AuthorizationProvider, AuthorizationState, Error, Governance,
    RefreshFailure, RefreshProvider, Result, Target, Work, Writer, recover_refreshes,
};
use codexone_identity_runtime::{
    IdentityRuntime, QuotaFailure, SubscriptionProvider, UsageCredits,
};
use codexone_storage::{AccountCredential, AccountCredentialCipher, Database};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};

const NOW: i64 = 1_700_000_000;
const CLIENT: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const NONCE: &str = "synthetic_nonce_0123456789012345678";
const VERIFIER: &str = "synthetic_verifier_01234567890123456789012345678";
const WAIT: Duration = Duration::from_secs(3);

#[cfg(feature = "test-support")]
use std::sync::atomic::AtomicUsize;
#[cfg(feature = "test-support")]
use tokio::sync::{Notify, oneshot};

#[derive(Clone)]
struct TestWriter(
    Arc<Mutex<Database>>,
    Arc<AtomicI64>,
    #[cfg(feature = "test-support")] Arc<WriterProbe>,
);

#[cfg(feature = "test-support")]
#[derive(Default)]
struct WriterProbe {
    in_flight: AtomicUsize,
    pause: Mutex<Option<(Work, Arc<WriterPause>)>>,
}

#[cfg(feature = "test-support")]
#[derive(Default)]
struct WriterPause {
    entered: Notify,
    on_accept: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    release: Notify,
    hold_reply: bool,
    replied: Notify,
    release_reply: Notify,
}

#[cfg(feature = "test-support")]
impl TestWriter {
    fn pause_next(&self, work: Work) -> Arc<WriterPause> {
        self.pause(work, false)
    }

    fn pause(&self, work: Work, hold_reply: bool) -> Arc<WriterPause> {
        let pause = Arc::new(WriterPause {
            hold_reply,
            ..WriterPause::default()
        });
        assert!(
            self.2
                .pause
                .lock()
                .unwrap()
                .replace((work, pause.clone()))
                .is_none()
        );
        pause
    }

    fn in_flight(&self) -> usize {
        self.2.in_flight.load(Ordering::SeqCst)
    }
}

impl Writer for TestWriter {
    async fn run<T: Send + 'static>(
        &self,
        _work: Work,
        operation: impl FnOnce(&mut Database, i64, bool) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        #[cfg(feature = "test-support")]
        let pause = {
            let mut pending = self.2.pause.lock().unwrap();
            if pending.as_ref().is_some_and(|(work, _)| *work == _work) {
                pending.take().map(|(_, pause)| pause)
            } else {
                None
            }
        };
        #[cfg(feature = "test-support")]
        if let Some(pause) = pause {
            let on_accept = pause.on_accept.lock().unwrap().take();
            if let Some(on_accept) = on_accept {
                on_accept();
            }
            let worker = self.clone();
            let (reply, receive) = oneshot::channel();
            // An accepted writer command outlives its cancelled caller.
            self.2.in_flight.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                pause.entered.notify_one();
                pause.release.notified().await;
                let result = operation(
                    &mut worker.0.lock().unwrap(),
                    worker.1.load(Ordering::Relaxed),
                    true,
                );
                if pause.hold_reply {
                    pause.replied.notify_one();
                    pause.release_reply.notified().await;
                }
                worker.2.in_flight.fetch_sub(1, Ordering::SeqCst);
                let _ = reply.send(result);
            });
            return receive.await.unwrap();
        }
        operation(
            &mut self.0.lock().unwrap(),
            self.1.load(Ordering::Relaxed),
            true,
        )
    }
}

struct Fixture {
    directory: TempDir,
    writer: TestWriter,
    governance: Arc<Governance<TestWriter>>,
    runtime: IdentityRuntime<TestWriter>,
    provider: SubscriptionProvider,
}

impl Fixture {
    fn new(auth: NonZeroU16, quota: NonZeroU16) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("synthetic.sqlite");
        let now = Arc::new(AtomicI64::new(NOW));
        let writer = TestWriter(
            Arc::new(Mutex::new(Database::open_or_create(path).unwrap())),
            now.clone(),
            #[cfg(feature = "test-support")]
            Arc::new(WriterProbe::default()),
        );
        let governance = Arc::new(Governance::new(writer.clone(), Some(cipher())));
        let provider = SubscriptionProvider::synthetic_loopback(auth, quota, move || {
            now.load(Ordering::Relaxed)
        });
        let runtime = IdentityRuntime::new(
            writer.clone(),
            governance.clone(),
            cipher(),
            provider.clone(),
        );
        Self {
            directory,
            writer,
            governance,
            runtime,
            provider,
        }
    }

    async fn authorize(&self, auth: &TcpListener, expires: i64) -> Account {
        let task = self.provider.authorize("synthetic-code", VERIFIER, NONCE);
        let response = async {
            let (mut socket, request) = accept(auth).await;
            assert!(request.head.starts_with("POST /oauth/token HTTP/1.1"));
            assert!(
                request
                    .head
                    .contains("content-type: application/x-www-form-urlencoded")
            );
            assert!(request.body.contains("code=synthetic-code"));
            assert!(
                request
                    .body
                    .contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")
            );
            reply(
                &mut socket,
                200,
                &token_doc("synthetic/account", expires, Some(NONCE)),
            )
            .await;
        };
        let (verified, ()) = tokio::join!(task, response);
        let verified = verified.unwrap();
        assert_eq!(verified.namespace, expected_namespace(port(auth)));
        self.governance
            .seal_verified(Target::Create, verified)
            .await
            .unwrap()
    }

    async fn current(&self) -> Account {
        self.governance
            .list_accounts(None)
            .await
            .unwrap()
            .pop()
            .unwrap()
    }

    async fn scalar<T: rusqlite::types::FromSql + Send + 'static>(&self, sql: &'static str) -> T {
        self.writer
            .run(Work::Read, |db, _, _| {
                Ok(db.connection().query_row(sql, [], |row| row.get(0))?)
            })
            .await
            .unwrap()
    }
}

fn expected_namespace(auth: NonZeroU16) -> String {
    // The exact array encoded by Foundation JSONEncoder for the synthetic realm.
    let encoded = format!(
        r#"["https:\/\/chatgpt.com\/backend-api\/codex","codex-subscription","http:\/\/127.0.0.1:{auth}","{CLIENT}","synthetic-subject","synthetic\/account"]"#
    );
    format!("subscription-{:x}", Sha256::digest(encoded.as_bytes()))
}

fn cipher() -> AccountCredentialCipher {
    AccountCredentialCipher::from_hex(&"77".repeat(32), &[]).unwrap()
}

fn jwt(account: &str, expires: i64, nonce: Option<&str>) -> String {
    let mut claims = json!({
        "iss": "https://auth.openai.com",
        "aud": CLIENT,
        "sub": "synthetic-subject",
        "exp": expires,
        "https://api.openai.com/auth": { "chatgpt_account_id": account, "chatgpt_user_id": "synthetic-user" },
    });
    if let Some(nonce) = nonce {
        claims["nonce"] = json!(nonce);
    }
    format!(
        "{}.{}.{}",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256"}"#),
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap()),
        URL_SAFE_NO_PAD.encode(b"synthetic")
    )
}

fn token_doc(account: &str, expires: i64, nonce: Option<&str>) -> Value {
    json!({
        "access_token": jwt(account, expires, None),
        "id_token": jwt(account, expires, nonce),
        "refresh_token": "synthetic-refresh",
        "token_type": "Bearer",
    })
}

async fn listener() -> TcpListener {
    TcpListener::bind(("127.0.0.1", 0)).await.unwrap()
}

fn port(listener: &TcpListener) -> NonZeroU16 {
    listener.local_addr().unwrap().port().try_into().unwrap()
}

struct Request {
    head: String,
    body: String,
}

async fn accept(listener: &TcpListener) -> (TcpStream, Request) {
    timeout(WAIT, async {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let boundary = loop {
            assert_ne!(socket.read_buf(&mut bytes).await.unwrap(), 0);
            if let Some(pos) = bytes.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                break pos + 4;
            }
            assert!(bytes.len() < 65_536);
        };
        let head = String::from_utf8(bytes[..boundary].to_vec()).unwrap();
        let size: usize = head
            .lines()
            .find_map(|line| line.strip_prefix("content-length: "))
            .unwrap_or("0")
            .parse()
            .unwrap();
        while bytes.len() < boundary + size {
            assert_ne!(socket.read_buf(&mut bytes).await.unwrap(), 0);
        }
        let body = String::from_utf8(bytes[boundary..boundary + size].to_vec()).unwrap();
        (socket, Request { head, body })
    })
    .await
    .unwrap()
}

async fn reply(socket: &mut TcpStream, status: u16, value: &Value) {
    let body = serde_json::to_vec(value).unwrap();
    let headers = format!(
        "HTTP/1.1 {status} Test\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    socket.write_all(headers.as_bytes()).await.unwrap();
    socket.write_all(&body).await.unwrap();
    socket.shutdown().await.unwrap();
}

#[tokio::test]
async fn cancelled_manual_waiter_does_not_cancel_shared_refresh_or_restore_old_mode() {
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    let runtime = fixture.runtime.clone();
    let id = account.id.clone();
    let task = tokio::spawn(async move { runtime.refresh_account(id, account.revision).await });
    let (mut socket, request) = accept(&auth).await;
    let request_body: Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(request_body["grant_type"], "refresh_token");
    assert_eq!(request_body["refresh_token"], "synthetic-refresh");
    let pending = fixture.current().await;
    assert_eq!(pending.authorization, AuthorizationState::Refreshing);
    assert!(pending.refresh_intent.is_some());

    task.abort();
    assert!(matches!(task.await, Err(error) if error.is_cancelled()));
    fixture
        .governance
        .set_account_mode(pending.id, pending.revision, AccountMode::Enabled)
        .await
        .unwrap();
    let waiter = fixture.runtime.prepare_dispatch(&account.id, false);
    let answer = async {
        let mut rotated = token_doc("synthetic/account", NOW + 7200, None);
        rotated["refresh_token"] = json!("synthetic-new-refresh");
        tokio::task::yield_now().await;
        reply(&mut socket, 200, &rotated).await;
    };
    let (prepared, ()) = tokio::join!(waiter, answer);
    let prepared = prepared.unwrap();
    assert_eq!(prepared.account.authorization, AuthorizationState::Ready);
    assert_eq!(prepared.account.mode, AccountMode::Enabled);
    assert_eq!(prepared.account.credential_version, 2);
    assert_eq!(prepared.expires_at_unix_seconds, NOW + 7200);
    assert_eq!(prepared.headers["chatgpt-account-id"], "synthetic/account");
    assert!(prepared.headers["authorization"].is_sensitive());
    assert_eq!(
        fixture
            .scalar::<i64>("SELECT COUNT(*) FROM account_events WHERE action='refresh_begin'")
            .await,
        1
    );
    fixture.runtime.shutdown().await;
}

#[tokio::test]
async fn explicit_rejection_and_dropped_response_leave_separate_durable_barriers() {
    for (response, expected) in [
        (
            Some(json!({"error": "invalid_grant"})),
            AuthorizationState::RequiresAuth,
        ),
        (
            Some(json!({"error": "invalid_grant", "access_token": null})),
            AuthorizationState::AuthUncertain,
        ),
        (None, AuthorizationState::AuthUncertain),
    ] {
        let auth = listener().await;
        let fixture = Fixture::new(port(&auth), port(&auth));
        let account = fixture.authorize(&auth, NOW + 3600).await;
        let wait = fixture
            .runtime
            .refresh_account(account.id.clone(), account.revision);
        let upstream = async {
            let (mut socket, _) = accept(&auth).await;
            if let Some(response) = response {
                reply(&mut socket, 401, &response).await;
            }
        };
        let (result, ()) = tokio::join!(wait, upstream);
        assert_eq!(
            result.err(),
            Some(if expected == AuthorizationState::RequiresAuth {
                Error::AuthorizationRequired
            } else {
                Error::AuthorizationUnavailable
            })
        );
        let current = fixture.current().await;
        assert_eq!(current.authorization, expected);
        assert_eq!(current.credential_version, 1);
        assert!(current.refresh_intent.is_some());
        assert!(
            fixture
                .runtime
                .refresh_account(account.id, current.revision)
                .await
                .is_err()
        );
        fixture.runtime.shutdown().await;
    }
}

#[tokio::test]
async fn shutdown_closes_socket_and_startup_recovers_an_unfinished_intent() {
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    let runtime = fixture.runtime.clone();
    let first = account.clone();
    let waiter =
        tokio::spawn(async move { runtime.refresh_account(first.id, first.revision).await });
    let (mut socket, _) = accept(&auth).await;
    timeout(WAIT, fixture.runtime.shutdown()).await.unwrap();
    let mut byte = [0u8; 1];
    assert_eq!(
        timeout(WAIT, socket.read(&mut byte))
            .await
            .unwrap()
            .unwrap(),
        0
    );
    assert!(waiter.await.unwrap().is_err());
    assert_eq!(
        fixture.current().await.authorization,
        AuthorizationState::AuthUncertain
    );

    // Simulate a crash immediately after a separate durable intent, by opening
    // a fresh database handle without attempting any provider or terminal write.
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    let _abandoned = fixture
        .governance
        .begin_refresh(account.id, account.revision)
        .await
        .unwrap();
    let Fixture {
        directory,
        governance,
        runtime,
        writer,
        ..
    } = fixture;
    drop((runtime, governance, writer));
    let mut db = Database::open_existing(directory.path().join("synthetic.sqlite")).unwrap();
    let tx = db.begin_immediate().unwrap();
    recover_refreshes(&tx, NOW).unwrap();
    tx.commit().unwrap();
    let (state, revision, version, intent) = db
        .connection()
        .query_row(
            "SELECT authorization,revision,credential_version,refresh_intent FROM accounts",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(
        (state.as_str(), revision, version),
        ("auth_uncertain", 3, 1)
    );
    assert!(!intent.is_empty());
}

#[tokio::test]
async fn proactive_connection_refusal_preserves_old_credential_for_a_passive_get() {
    let auth = listener().await;
    let quota = listener().await;
    let fixture = Fixture::new(port(&auth), port(&quota));
    let account = fixture.authorize(&auth, NOW + 899).await;
    fixture
        .governance
        .set_account_mode(account.id.clone(), account.revision, AccountMode::Enabled)
        .await
        .unwrap();
    drop(auth);
    let observation = fixture.runtime.observe_account(&account.id);
    let upstream = async {
        let (mut socket, request) = accept(&quota).await;
        assert!(
            request
                .head
                .starts_with("GET /backend-api/wham/usage HTTP/1.1")
        );
        assert!(request.body.is_empty());
        assert!(
            request
                .head
                .contains("chatgpt-account-id: synthetic/account")
        );
        assert!(!request.head.to_ascii_lowercase().contains("reserve"));
        reply(&mut socket, 200, &json!({"rate_limit": {"allowed": true}})).await;
    };
    let (result, ()) = tokio::join!(observation, upstream);
    assert!(result.unwrap().quota.unwrap().limits[0].allowed.unwrap());
    let current = fixture.current().await;
    assert_eq!(current.authorization, AuthorizationState::Ready);
    assert_eq!(current.credential_version, 1);
    assert_eq!(
        fixture
            .scalar::<String>("SELECT action FROM account_events ORDER BY revision DESC LIMIT 1")
            .await,
        "refresh_not_completed"
    );
    fixture.runtime.shutdown().await;
}

#[tokio::test]
async fn passive_observation_preserves_success_on_failure_and_rejects_old_version() {
    let auth = listener().await;
    let quota = listener().await;
    let fixture = Fixture::new(port(&auth), port(&quota));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    // Disabled accounts are intentionally eligible for explicit passive observation only.
    fixture.runtime.schedule_cycle().await.unwrap();
    let task = fixture.runtime.observe_account(&account.id);
    let upstream = async {
        let (mut socket, _) = accept(&quota).await;
        reply(&mut socket, 200, &json!({
            "account_id": "synthetic/account",
            "rate_limit": {"primary_window": {
                "used_percent": 26.25, "limit_window_seconds": 3600,
                "reset_at": NOW + 1800, "reset_after_seconds": 1800
            }},
            "credits": {"balance": "20.25", "unlimited": false, "private_field": "synthetic-private"},
            "email": "synthetic-private"
        })).await;
    };
    let (result, ()) = tokio::join!(task, upstream);
    let success = result.unwrap();
    assert_eq!(
        success.quota.as_ref().unwrap().usage_credits,
        Some(UsageCredits::Balance { _0: "20.25".into() })
    );
    assert!(success.is_fresh(NOW));
    assert!(!success.is_fresh(NOW - 1));
    assert!(!success.is_fresh(NOW + 300));
    assert_eq!(
        fixture
            .scalar::<String>("SELECT balance FROM account_credit_samples")
            .await,
        "20.25"
    );
    assert_eq!(
        fixture
            .scalar::<String>("SELECT remaining FROM account_quota_cycle_samples")
            .await,
        "73.75"
    );
    let stored = fixture
        .scalar::<String>("SELECT record_json FROM account_quota")
        .await;
    assert!(!stored.contains("synthetic-private"));
    if let Some(path) = std::env::var_os("CODEXONE_RUST_QUOTA_RECORD") {
        std::fs::write(path, &stored).unwrap();
    }
    if let Some(path) = std::env::var_os("CODEXONE_SWIFT_QUOTA_RECORD") {
        let swift_record = std::fs::read_to_string(path).unwrap();
        let id = account.id.clone();
        fixture
            .writer
            .run(Work::Optional, move |db, _, _| {
                db.connection().execute(
                    "UPDATE account_quota SET record_json=? WHERE account_id=?",
                    rusqlite::params![swift_record, id],
                )?;
                Ok(())
            })
            .await
            .unwrap();
        assert_eq!(fixture.runtime.quota(&account.id).await.unwrap(), success);
    }

    assert_eq!(
        serde_json::from_str::<Value>(&stored).unwrap()["quota"]["usageCredits"],
        json!({"balance":{"_0":"20.25"}})
    );

    fixture.writer.1.fetch_add(30, Ordering::Relaxed);
    let task = fixture.runtime.observe_account(&account.id);
    let upstream = async {
        let (mut socket, _) = accept(&quota).await;
        reply(&mut socket, 429, &json!({"private": "synthetic-private"})).await;
    };
    let (result, ()) = tokio::join!(task, upstream);
    let failed = result.unwrap();
    assert_eq!(failed.failure, Some(QuotaFailure::RateLimited));
    assert_eq!(failed.attempted_at_unix_seconds, Some(NOW + 30));
    assert_eq!(failed.observed_at_unix_seconds, Some(NOW));
    assert_eq!(failed.quota, success.quota);
    assert_eq!(
        fixture
            .scalar::<i64>("SELECT COUNT(*) FROM account_health")
            .await,
        0
    );

    let runtime = fixture.runtime.clone();
    let id = account.id.clone();
    let observe = tokio::spawn(async move { runtime.observe_account(&id).await });
    let (mut socket, _) = accept(&quota).await;
    let refresh = fixture
        .runtime
        .refresh_account(account.id.clone(), account.revision);
    let upstream = async {
        let (mut socket, _) = accept(&auth).await;
        reply(
            &mut socket,
            200,
            &token_doc("synthetic/account", NOW + 7200, None),
        )
        .await;
    };
    let (updated, ()) = tokio::join!(refresh, upstream);
    assert_eq!(updated.unwrap().credential_version, 2);
    reply(&mut socket, 200, &json!({"rate_limit": {"allowed": false}})).await;
    assert_eq!(observe.await.unwrap().err(), Some(Error::AccountConflict));
    assert_eq!(fixture.runtime.quota(&account.id).await.unwrap(), failed);
    fixture.runtime.shutdown().await;
}

#[tokio::test]
async fn verified_tokens_cannot_cross_realms_and_fresh_claims_must_keep_scope() {
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    let credential = AccountCredential::new(
        jwt("synthetic/account", NOW + 3600, None),
        "synthetic-refresh".into(),
        Some(jwt("synthetic/account", NOW - 60, None)),
        NOW + 3600,
    )
    .unwrap();
    assert!(
        fixture
            .provider
            .verified_headers(&account.namespace, &credential)
            .is_some()
    );
    let other = listener().await;
    let other_provider =
        SubscriptionProvider::synthetic_loopback(port(&other), port(&other), || NOW);
    assert!(
        other_provider
            .verified_headers(&account.namespace, &credential)
            .is_none()
    );
    assert!(matches!(
        other_provider
            .refresh(&credential, &account.namespace)
            .await,
        Err(RefreshFailure::Unknown)
    ));

    let wait = fixture
        .runtime
        .refresh_account(account.id, account.revision);
    let upstream = async {
        let (mut socket, _) = accept(&auth).await;
        reply(
            &mut socket,
            200,
            &token_doc("different-account", NOW + 7200, None),
        )
        .await;
    };
    let (result, ()) = tokio::join!(wait, upstream);
    assert_eq!(result.err(), Some(Error::AuthorizationUnavailable));
    assert_eq!(
        fixture.current().await.authorization,
        AuthorizationState::AuthUncertain
    );
    fixture.runtime.shutdown().await;
}

#[tokio::test]
async fn quota_waiter_cancellation_and_shutdown_own_the_live_get() {
    let auth = listener().await;
    let quota = listener().await;
    let fixture = Fixture::new(port(&auth), port(&quota));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    #[cfg(feature = "test-support")]
    let (_, driver) = fixture.provider.driver_probes();
    let runtime = fixture.runtime.clone();
    let id = account.id.clone();
    let waiter = tokio::spawn(async move { runtime.observe_account(&id).await });
    let (mut socket, _) = accept(&quota).await;
    #[cfg(feature = "test-support")]
    assert_eq!(driver.counts(), (1, 0));
    waiter.abort();
    assert!(matches!(waiter.await, Err(error) if error.is_cancelled()));

    let shared = fixture.runtime.observe_account(&account.id);
    let close = async {
        // The new waiter is polled by join before the first yield.
        tokio::task::yield_now().await;
        assert!(
            timeout(Duration::from_millis(40), quota.accept())
                .await
                .is_err()
        );
        timeout(WAIT, fixture.runtime.shutdown()).await.unwrap();
        #[cfg(feature = "test-support")]
        assert_eq!(driver.counts(), (1, 1));
        let mut byte = [0u8; 1];
        assert_eq!(
            timeout(WAIT, socket.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    };
    let (result, ()) = tokio::join!(shared, close);
    assert_eq!(result.err(), Some(Error::AuthorizationUnavailable));
    assert_eq!(
        fixture
            .scalar::<i64>("SELECT COUNT(*) FROM account_quota")
            .await,
        0
    );
}

#[tokio::test]
async fn device_authorization_matches_pending_poll_and_pkce_exchange() {
    let auth = listener().await;
    let provider = SubscriptionProvider::synthetic_loopback(port(&auth), port(&auth), || NOW);
    let upstream = async {
        let (mut socket, request) = accept(&auth).await;
        assert!(
            request
                .head
                .starts_with("POST /api/accounts/deviceauth/usercode ")
        );
        assert_eq!(
            serde_json::from_str::<Value>(&request.body).unwrap()["client_id"],
            CLIENT
        );
        reply(
            &mut socket,
            200,
            &json!({
                "device_auth_id": "synthetic-device", "user_code": "SYNTHETIC",
                "interval": "5", "expires_in": 180,
            }),
        )
        .await;
    };
    let (code, ()) = tokio::join!(provider.request_device_code(), upstream);
    let code = code.unwrap();
    assert_eq!(code.interval_seconds, 5);
    assert_eq!(code.expires_in_seconds, 180);

    for status in [403, 200] {
        let poll = provider.poll_device_code(&code);
        let upstream =
            async {
                let (mut socket, request) = accept(&auth).await;
                assert!(
                    request
                        .head
                        .starts_with("POST /api/accounts/deviceauth/token ")
                );
                assert_eq!(
                    serde_json::from_str::<Value>(&request.body).unwrap()["device_auth_id"],
                    "synthetic-device"
                );
                reply(&mut socket, status, &json!({
                "authorization_code": "synthetic-device-code",
                "code_verifier": VERIFIER,
                "code_challenge": URL_SAFE_NO_PAD.encode(Sha256::digest(VERIFIER.as_bytes())),
            })).await;
            };
        let (grant, ()) = tokio::join!(poll, upstream);
        let grant = match grant.ok().expect("device poll") {
            None if status == 403 => continue,
            Some(grant) if status == 200 => grant,
            _ => panic!("unexpected poll outcome"),
        };
        let exchange = provider.authorize_device(&grant);
        let upstream = async {
            let (mut socket, request) = accept(&auth).await;
            assert!(request.body.contains("%2Fdeviceauth%2Fcallback"));
            reply(
                &mut socket,
                200,
                &token_doc("synthetic/account", NOW + 3600, None),
            )
            .await;
        };
        let (verified, ()) = tokio::join!(exchange, upstream);
        assert_eq!(verified.unwrap().namespace, expected_namespace(port(&auth)));
    }
}

#[cfg(feature = "test-support")]
#[tokio::test]
async fn cancellation_and_deadline_end_the_refresh_driver_before_terminal_write() {
    for (received_headers, expire) in [(false, false), (true, false), (true, true)] {
        let auth = listener().await;
        let fixture = Fixture::new(port(&auth), port(&auth));
        let account = fixture.authorize(&auth, NOW + 3600).await;
        let (driver, _) = fixture.provider.driver_probes();
        assert_eq!(driver.counts(), (1, 1));

        let runtime = fixture.runtime.clone();
        let waiter =
            tokio::spawn(
                async move { runtime.refresh_account(account.id, account.revision).await },
            );
        let (mut socket, _) = accept(&auth).await;
        if received_headers {
            socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 900\r\n\r\n{")
                .await.unwrap();
            timeout(WAIT, async {
                while driver.received_headers() < 2 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }
        assert_eq!(driver.counts(), (2, 1));
        assert_eq!(driver.received_headers(), 1 + usize::from(received_headers));
        waiter.abort();
        assert!(matches!(waiter.await, Err(error) if error.is_cancelled()));
        assert_eq!(driver.counts(), (2, 1));

        let finish = fixture.writer.pause_next(Work::Critical);
        let driver_at_submission = driver.clone();
        *finish.on_accept.lock().unwrap() = Some(Box::new(move || {
            assert_eq!(driver_at_submission.counts(), (2, 2));
        }));

        if expire {
            tokio::time::pause();
            tokio::time::advance(Duration::from_secs(10)).await;
            timeout(WAIT, finish.entered.notified()).await.unwrap();
        }
        let shutdown = fixture.runtime.shutdown();
        tokio::pin!(shutdown);
        if expire {
            tokio::select! {
                biased;
                () = &mut shutdown => panic!("shutdown returned with the timeout terminal write pending"),
                () = tokio::task::yield_now() => {}
            }
        } else {
            tokio::select! {
                () = &mut shutdown => panic!("shutdown returned with a terminal write pending"),
                result = timeout(WAIT, finish.entered.notified()) => result.unwrap(),
            }
        }
        assert_eq!(driver.counts(), (2, 2));
        assert_eq!(fixture.writer.in_flight(), 1);
        assert_eq!(
            fixture.current().await.authorization,
            AuthorizationState::Refreshing
        );
        finish.release.notify_one();
        timeout(WAIT, &mut shutdown).await.unwrap();
        assert_eq!(fixture.writer.in_flight(), 0);
        let terminal = fixture.current().await;
        assert_eq!(terminal.authorization, AuthorizationState::AuthUncertain);
        assert_eq!(terminal.credential_version, 1);
        assert!(terminal.refresh_intent.is_some());
        let mut byte = [0u8; 1];
        assert_eq!(
            timeout(WAIT, socket.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }
}

#[cfg(feature = "test-support")]
#[tokio::test]
async fn shutdown_waits_for_commit_of_already_verified_rotation() {
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let account = fixture.authorize(&auth, NOW + 3600).await;
    let (driver, _) = fixture.provider.driver_probes();
    let runtime = fixture.runtime.clone();
    let waiter =
        tokio::spawn(async move { runtime.refresh_account(account.id, account.revision).await });
    let (mut socket, _) = accept(&auth).await;
    let finish = fixture.writer.pause_next(Work::Critical);
    reply(
        &mut socket,
        200,
        &token_doc("synthetic/account", NOW + 7200, None),
    )
    .await;
    timeout(WAIT, finish.entered.notified()).await.unwrap();
    assert_eq!(driver.counts(), (2, 2));

    waiter.abort();
    assert!(matches!(waiter.await, Err(error) if error.is_cancelled()));
    let shutdown = fixture.runtime.shutdown();
    tokio::pin!(shutdown);
    tokio::select! {
        biased;
        () = &mut shutdown => panic!("shutdown returned before the credential commit"),
        () = tokio::task::yield_now() => {}
    }
    assert_eq!(fixture.writer.in_flight(), 1);
    finish.release.notify_one();
    timeout(WAIT, &mut shutdown).await.unwrap();

    assert_eq!(fixture.writer.in_flight(), 0);
    let terminal = fixture.current().await;
    assert_eq!(terminal.authorization, AuthorizationState::Ready);
    assert_eq!(terminal.credential_version, 2);
    assert_eq!(terminal.mode, AccountMode::Disabled);
    assert!(terminal.refresh_intent.is_none());
}

#[cfg(feature = "test-support")]
#[tokio::test]
async fn identity_shutdown_waits_for_accepted_scan_after_caller_cancellation() {
    let auth = listener().await;
    let fixture = Fixture::new(port(&auth), port(&auth));
    let pause = fixture.writer.pause(Work::Read, true);
    let runtime = fixture.runtime.clone();
    let scan = tokio::spawn(async move { runtime.schedule_cycle().await });
    timeout(WAIT, pause.entered.notified()).await.unwrap();
    scan.abort();
    assert!(matches!(scan.await, Err(error) if error.is_cancelled()));

    let shutdown = fixture.runtime.shutdown();
    tokio::pin!(shutdown);
    tokio::select! {
        biased;
        () = &mut shutdown => panic!("shutdown returned with an accepted read pending"),
        () = tokio::task::yield_now() => {}
    }
    assert_eq!(fixture.writer.in_flight(), 1);
    assert_eq!(
        fixture.runtime.schedule_cycle().await,
        Err(Error::AuthorizationUnavailable)
    );
    pause.release.notify_one();
    tokio::select! {
        () = &mut shutdown => panic!("shutdown returned before the writer replied"),
        result = timeout(WAIT, pause.replied.notified()) => result.unwrap(),
    }
    assert_eq!(fixture.writer.in_flight(), 1);
    pause.release_reply.notify_one();
    timeout(WAIT, &mut shutdown).await.unwrap();
    assert_eq!(fixture.writer.in_flight(), 0);
}
