use std::{
    future::pending,
    num::NonZeroU16,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

use bytes::Bytes;
use codexone_admin::AdminRouter;
use codexone_governance::{
    AccountMode, AuthorizationProvider, AuthorizationState, Authorizations, DeviceCode,
    DeviceGrant, Error, FailureCode, Governance, GovernanceApi, KeyChange, KeyOptions, KeyPolicy,
    Limits, NoAccountRuntime, PollError, ProviderFailure, RefreshFailure, RefreshProvider,
    RefreshService, Result, Target, VerifiedAuthorization, Work, Writer, recover_refreshes,
};
use codexone_storage::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, Database, key_digest,
};
use http::{Request, Response};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Notify;
use zeroize::Zeroizing;

const NOW: i64 = 1_700_000_000;
const SECRET: &str = "synthetic-admin-governance-secret-for-tests";
const HOST: &str = "127.0.0.1:19876";
const ORIGIN: &str = "http://127.0.0.1:19876";

struct TestWriter {
    db: Mutex<Database>,
    optional: AtomicBool,
    hold: Mutex<Option<Arc<Hold>>>,
}

struct Hold {
    entered: Notify,
    release: Notify,
}

#[derive(Clone)]
struct SharedWriter(Arc<TestWriter>);

impl Writer for SharedWriter {
    async fn run<T: Send + 'static>(
        &self,
        work: Work,
        operation: impl FnOnce(&mut Database, i64, bool) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let hold = if work == Work::Optional {
            self.0.hold.lock().unwrap().take()
        } else {
            None
        };
        if let Some(hold) = hold {
            hold.entered.notify_one();
            hold.release.notified().await;
        }
        let optional = self.0.optional.load(Ordering::SeqCst);
        if !optional && work == Work::Optional {
            return Err(Error::StoragePressure);
        }
        operation(&mut self.0.db.lock().unwrap(), NOW, optional)
    }
}

struct Fixture {
    _dir: TempDir,
    writer: SharedWriter,
    governance: Arc<Governance<SharedWriter>>,
}

impl Fixture {
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let db = Database::open_or_create(dir.path().join("synthetic.sqlite")).unwrap();
        let writer = SharedWriter(Arc::new(TestWriter {
            db: Mutex::new(db),
            optional: AtomicBool::new(true),
            hold: Mutex::new(None),
        }));
        let governance = Arc::new(Governance::new(writer.clone(), Some(cipher())));
        Self {
            _dir: dir,
            writer,
            governance,
        }
    }

    fn sql(&self, sql: &str) {
        self.writer
            .0
            .db
            .lock()
            .unwrap()
            .connection()
            .execute_batch(sql)
            .unwrap();
    }

    fn field<T: rusqlite::types::FromSql>(&self, sql: &str) -> T {
        self.writer
            .0
            .db
            .lock()
            .unwrap()
            .connection()
            .query_row(sql, [], |row| row.get(0))
            .unwrap()
    }
}

fn cipher() -> AccountCredentialCipher {
    AccountCredentialCipher::from_hex(&"67".repeat(32), &[]).unwrap()
}

fn verified(namespace: &str) -> VerifiedAuthorization {
    VerifiedAuthorization {
        namespace: namespace.into(),
        credential: AccountCredential::new(
            "synthetic-access".into(),
            "synthetic-refresh".into(),
            None,
            NOW + 3600,
        )
        .unwrap(),
    }
}

fn policy() -> KeyPolicy {
    KeyPolicy {
        models: Some(vec!["synthetic-text".into()]),
        limits: Limits {
            tokens: Some(480),
            active: Some(2),
        },
        vision_input: false,
        image_generation: false,
        image_models: Some(vec![]),
        reasoning_efforts: Some([("synthetic-text".into(), vec!["low".into()])].into()),
    }
}

#[tokio::test]
async fn key_audit_and_digest_commit_atomically_with_revocation_reserve() {
    // Counterparts in Swift KeyGovernanceTests: rotation, audit failure and revocation reserve.
    let fixture = Fixture::new();
    let governance = &fixture.governance;
    let (key, secret) = governance
        .issue_key("synthetic-principal".into(), policy(), Some(0))
        .await
        .unwrap();
    assert_eq!(
        fixture.field::<String>("SELECT digest FROM managed_keys"),
        key_digest(&secret)
    );
    assert_eq!(secret.len(), 47);
    assert!(secret.starts_with("co1_"));
    fixture.sql(
        "CREATE TRIGGER fail_audit BEFORE INSERT ON key_events BEGIN SELECT RAISE(ABORT,'synthetic'); END",
    );
    assert_eq!(
        governance.rotate_key(key.id.clone(), 1).await.unwrap_err(),
        Error::Unavailable
    );
    assert_eq!(
        fixture.field::<String>("SELECT digest FROM managed_keys"),
        key_digest(&secret)
    );
    assert_eq!(fixture.field::<i64>("SELECT COUNT(*) FROM key_events"), 1);
    fixture.sql("DROP TRIGGER fail_audit");
    let (rotated, next_secret) = governance.rotate_key(key.id.clone(), 1).await.unwrap();
    assert_eq!(rotated.revision, 2);
    assert_eq!(rotated.principal, key.principal);
    assert_eq!(rotated.policy, key.policy);
    assert_eq!(
        fixture.field::<String>("SELECT digest FROM managed_keys"),
        key_digest(&next_secret)
    );
    assert_eq!(
        governance.rotate_key(key.id.clone(), 1).await.unwrap_err(),
        Error::Conflict
    );
    let metadata = fixture.field::<String>("SELECT metadata_json FROM managed_keys");
    let audit =
        fixture.field::<String>("SELECT metadata_json FROM key_events WHERE action='rotate'");
    assert_eq!(metadata, audit);
    assert!(!metadata.contains(secret.as_str()) && !metadata.contains(next_secret.as_str()));

    fixture.sql("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4094)
                 INSERT INTO key_events SELECT 'audit-'||i,id,1,'synthetic',1,'{}' FROM n,managed_keys");
    let change = |enabled| KeyChange::Policy {
        enabled,
        policy: KeyPolicy {
            reasoning_efforts: None,
            ..policy()
        },
        catalog_revision: Some(0),
    };
    assert_eq!(
        governance
            .change_key(key.id.clone(), 2, change(true))
            .await
            .unwrap_err(),
        Error::Capacity
    );

    fixture.writer.0.optional.store(false, Ordering::SeqCst);
    let (left, right) = tokio::join!(
        governance.change_key(key.id.clone(), 2, change(false)),
        governance.change_key(key.id.clone(), 2, change(false)),
    );
    let (disabled, stale) = match (left, right) {
        (Ok(key), Err(err)) | (Err(err), Ok(key)) => (key, err),
        pair => panic!("expected one winner: {pair:?}"),
    };
    assert_eq!(stale, Error::Conflict);
    assert_eq!(disabled.revision, 3);
    assert!(!disabled.enabled);
    assert_eq!(
        disabled.policy.reasoning_efforts,
        key.policy.reasoning_efforts
    );
    assert_eq!(
        governance
            .change_key(key.id.clone(), 3, change(false))
            .await
            .unwrap_err(),
        Error::StoragePressure
    );
    assert_eq!(
        fixture.field::<i64>("SELECT COUNT(*) FROM key_events"),
        4097
    );
}

#[tokio::test]
async fn existing_swift_key_shape_preserves_unrestricted_and_empty_fields() {
    let fixture = Fixture::new();
    fixture.sql(r#"INSERT INTO managed_keys VALUES('synthetic-key','synthetic-digest',
        '{"id":"synthetic-key","principal":"synthetic-principal","revision":1,"enabled":true,
          "createdAtUnixSeconds":1700000000,"policy":{"models":null,"limits":{"active":2,"requests":12}}}')"#);
    let keys = fixture.governance.list_keys(None, false).await.unwrap();
    assert_eq!(keys[0].policy.models, None);
    assert_eq!(keys[0].policy.image_models, Some(vec![]));
    assert_eq!(
        keys[0].policy.limits,
        Limits {
            tokens: None,
            active: Some(2)
        }
    );
    assert_eq!(
        fixture
            .governance
            .change_key("synthetic-key".into(), 1, KeyChange::Archive(true))
            .await
            .unwrap_err(),
        Error::KeyEnabled
    );
    assert_eq!(
        fixture
            .governance
            .issue_key("synthetic".into(), policy(), Some(1))
            .await
            .unwrap_err(),
        Error::Conflict
    );
}

#[tokio::test]
async fn refresh_not_completed_resumes_only_with_unexpired_access() {
    let fixture = Fixture::new();
    for (expires, expected) in [
        (NOW + 1, AuthorizationState::Ready),
        (NOW, AuthorizationState::AuthUncertain),
    ] {
        let verified = VerifiedAuthorization {
            namespace: format!("synthetic/refresh-{expires}"),
            credential: AccountCredential::new(
                "synthetic-access".into(),
                "synthetic-refresh".into(),
                None,
                expires,
            )
            .unwrap(),
        };
        let account = fixture
            .governance
            .seal_verified(Target::Create, verified)
            .await
            .unwrap();
        let intent = fixture
            .governance
            .begin_refresh(account.id, 1)
            .await
            .unwrap();
        let abandoned = fixture.governance.abandon_refresh(&intent).await.unwrap();
        assert_eq!(abandoned.authorization, expected);
        assert_eq!(abandoned.credential_version, 1);
    }
}

#[tokio::test]
async fn account_reauthorization_enforces_identity_and_refresh_recovery() {
    let fixture = Fixture::new();
    let governance = &fixture.governance;
    let account = governance
        .seal_verified(Target::Create, verified("synthetic/realm"))
        .await
        .unwrap();
    assert_eq!(account.mode, AccountMode::Disabled);
    assert_eq!(account.authorization, AuthorizationState::Ready);
    assert_eq!(
        governance
            .credential_times(account.id.clone())
            .await
            .unwrap(),
        (Some(NOW), Some(NOW + 3600))
    );
    assert!(matches!(
        governance
            .seal_verified(Target::Create, verified("synthetic/realm"))
            .await,
        Err(Error::IdentityMismatch)
    ));
    let target = |revision| Target::Reauthorize {
        id: account.id.clone(),
        revision,
    };
    assert!(matches!(
        governance
            .seal_verified(target(1), verified("synthetic/other"))
            .await,
        Err(Error::IdentityMismatch)
    ));
    fixture.sql("CREATE TRIGGER fail_audit BEFORE INSERT ON account_events BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    assert!(matches!(
        governance
            .seal_verified(target(1), verified("synthetic/realm"))
            .await,
        Err(Error::Unavailable)
    ));
    assert_eq!(
        fixture.field::<i64>("SELECT credential_version FROM accounts"),
        1
    );
    fixture.sql("DROP TRIGGER fail_audit");

    let replacement = governance
        .seal_verified(target(1), verified("synthetic/realm"))
        .await
        .unwrap();
    assert_eq!(
        (replacement.revision, replacement.credential_version),
        (2, 2)
    );
    let envelope = fixture.field::<String>("SELECT sealed_credential FROM accounts");
    let context = AccountCredentialContext::new(&account.id, &account.namespace, 2).unwrap();
    assert_eq!(
        cipher().open(&envelope, &context).unwrap().access_token(),
        "synthetic-access"
    );
    let pending = governance
        .begin_refresh(account.id.clone(), 2)
        .await
        .unwrap();
    assert!(matches!(
        governance
            .seal_verified(target(3), verified("synthetic/realm"))
            .await,
        Err(Error::Conflict)
    ));
    fixture
        .writer
        .run(Work::Critical, |db, now, _| {
            let tx = db.begin_immediate()?;
            recover_refreshes(&tx, now)?;
            tx.commit()?;
            Ok(())
        })
        .await
        .unwrap();
    assert_eq!(
        fixture.field::<String>("SELECT authorization FROM accounts"),
        "auth_uncertain"
    );
    assert!(matches!(
        governance
            .finish_refresh(&pending, verified("synthetic/realm"))
            .await,
        Err(Error::Conflict)
    ));
    assert_eq!(
        fixture.field::<String>("SELECT action FROM account_events WHERE revision=4"),
        "refresh_restart_uncertain"
    );
    assert!(
        !fixture
            .field::<String>("SELECT metadata_json FROM account_events WHERE revision=4")
            .contains("synthetic-access")
    );
}

#[derive(Default)]
struct Provider {
    callbacks: AtomicUsize,
    polls: AtomicUsize,
    exchanges: AtomicUsize,
    no_response: bool,
}

struct MockProvider(Arc<Provider>);

impl AuthorizationProvider for MockProvider {
    fn authorization_url(
        &self,
        state: &str,
        _nonce: &str,
        _verifier: &str,
    ) -> std::result::Result<String, FailureCode> {
        Ok(format!("https://synthetic.example/authorize?state={state}"))
    }

    async fn authorize(
        &self,
        code: &str,
        _verifier: &str,
        _nonce: &str,
    ) -> std::result::Result<VerifiedAuthorization, ProviderFailure> {
        self.0.callbacks.fetch_add(1, Ordering::SeqCst);
        assert_eq!(code, "synthetic-code");
        Ok(verified("synthetic/callback"))
    }

    async fn request_device_code(&self) -> std::result::Result<DeviceCode, ProviderFailure> {
        Ok(DeviceCode {
            device_auth_id: Zeroizing::new("synthetic-private-device-id".into()),
            user_code: Zeroizing::new("SYNTH-CODE".into()),
            verification_url: "https://synthetic.example/device".into(),
            interval_seconds: 1,
            expires_in_seconds: 900,
        })
    }

    async fn poll_device_code(
        &self,
        code: &DeviceCode,
    ) -> std::result::Result<Option<DeviceGrant>, PollError> {
        assert_eq!(code.device_auth_id.as_str(), "synthetic-private-device-id");
        let poll = self.0.polls.fetch_add(1, Ordering::SeqCst);
        match poll {
            _ if self.0.no_response => Err(PollError::NoResponse),
            0 => Err(PollError::NoResponse),
            1 => Ok(None),
            _ => Ok(Some(DeviceGrant {
                code: Zeroizing::new("synthetic-grant".into()),
                verifier: Zeroizing::new("synthetic-verifier".into()),
            })),
        }
    }

    async fn authorize_device(
        &self,
        grant: &DeviceGrant,
    ) -> std::result::Result<VerifiedAuthorization, ProviderFailure> {
        self.0.exchanges.fetch_add(1, Ordering::SeqCst);
        assert_eq!(grant.code.as_str(), "synthetic-grant");
        Ok(verified("synthetic/device"))
    }
}

type Api = GovernanceApi<SharedWriter, MockProvider, NoAccountRuntime>;

fn management(fixture: &Fixture, provider: Arc<Provider>) -> (AdminRouter, Arc<Api>) {
    let admin = AdminRouter::new(
        NonZeroU16::new(19876).unwrap(),
        None,
        Some(decode_digest(&key_digest(SECRET))),
        None,
        None,
    );
    let authorization = Authorizations::new(fixture.governance.clone(), MockProvider(provider));
    let api = GovernanceApi::new(
        fixture.governance.clone(),
        Some(authorization),
        NoAccountRuntime,
    );
    (admin, Arc::new(api))
}

fn decode_digest(hex: &str) -> [u8; 32] {
    std::array::from_fn(|index| u8::from_str_radix(&hex[2 * index..2 * index + 2], 16).unwrap())
}

fn request(
    method: &str,
    path: &str,
    body: Option<Value>,
    headers: &[(&str, &str)],
) -> Request<Bytes> {
    let mut builder = Request::builder().method(method).uri(path);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    if body.is_some() {
        builder = builder.header("content-type", "application/json");
    }
    builder
        .body(body.map_or_else(Bytes::new, |body| body.to_string().into()))
        .unwrap()
}

async fn headless(
    api: &Api,
    admin: &AdminRouter,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> Response<Bytes> {
    let request = request(
        method,
        path,
        body,
        &[("authorization", &format!("Bearer {SECRET}"))],
    );
    api.route(admin, &request, KeyOptions::default)
        .await
        .unwrap()
}

fn document(response: &Response<Bytes>, status: u16) -> Value {
    assert_eq!(response.status(), status);
    assert_eq!(response.headers()["cache-control"], "no-store");
    serde_json::from_slice(response.body()).unwrap()
}

fn error(response: &Response<Bytes>, status: u16, code: &str) {
    let doc = document(response, status);
    assert_eq!(doc["error"]["code"], code);
    assert_eq!(doc["error"]["message"], "Management request failed.");
    assert!(uuid::Uuid::parse_str(doc["error"]["request_id"].as_str().unwrap()).is_ok());
}

async fn login(admin: &AdminRouter) -> (String, String) {
    let request = request(
        "POST",
        "/api/session",
        Some(json!({"username": "admin", "secret": SECRET})),
        &[("host", HOST), ("origin", ORIGIN)],
    );
    let response = admin
        .route(&request, async || panic!("unexpected readiness"))
        .await
        .unwrap();
    let doc = document(&response, 200);
    let cookie = response.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap();
    (cookie.into(), doc["csrf"].as_str().unwrap().into())
}

#[tokio::test]
async fn key_http_contract_matches_swift_metadata_and_errors() {
    let fixture = Fixture::new();
    let (admin, api) = management(&fixture, Arc::new(Provider::default()));
    let keys_only = GovernanceApi::keys_only(fixture.governance.clone());
    let accounts = request("GET", "/api/accounts", None, &[]);
    assert!(
        keys_only
            .route(&admin, &accounts, KeyOptions::default)
            .await
            .is_none()
    );
    let create = |revision| {
        json!({
            "principal": "synthetic-principal", "models": ["synthetic-text"],
            "limits": {"active": null, "tokens": 30}, "catalogRevision": revision
        })
    };
    let invalid = headless(&api, &admin, "POST", "/api/keys", Some(create(1))).await;
    error(&invalid, 409, "revision_conflict");
    let issued = headless(&api, &admin, "POST", "/api/keys", Some(create(0))).await;
    let issued = document(&issued, 201);
    let id = issued["key"]["id"].as_str().unwrap();
    let key_uri = format!("/api/keys/{id}");
    let expected = json!({
        "id": id, "principal": "synthetic-principal", "revision": 1, "enabled": true,
        "models": ["synthetic-text"], "limits": {"active": null, "tokens": 30},
        "visionInput": false, "imageGeneration": false, "imageModels": [], "reasoningEfforts": {},
        "displayName": null, "archivedAtUnixSeconds": null, "expiresAtUnixSeconds": null,
        "createdAtUnixSeconds": NOW
    });
    assert_eq!(issued["key"], expected);
    let list = headless(&api, &admin, "GET", "/api/keys?archived=false", None).await;
    assert_eq!(
        document(&list, 200),
        json!({"keys": [expected], "nextCursor": null})
    );
    let duplicate_query = headless(
        &api,
        &admin,
        "GET",
        "/api/keys?archived=true&archived=false",
        None,
    )
    .await;
    error(&duplicate_query, 400, "invalid_command");
    let archive = format!("{key_uri}/archive");
    let enabled = headless(&api, &admin, "PUT", &archive, Some(json!({"revision":1}))).await;
    error(&enabled, 409, "key_enabled");
    let disabled = headless(&api, &admin, "PUT", &key_uri, Some(json!({
        "revision": 1, "enabled": false, "models": ["synthetic-text"], "limits": {"active":null,"tokens":30}
    }))).await;
    assert_eq!(document(&disabled, 200)["key"]["enabled"], false);
    let archived = headless(&api, &admin, "PUT", &archive, Some(json!({"revision":2}))).await;
    assert_eq!(
        document(&archived, 200)["key"]["archivedAtUnixSeconds"],
        NOW
    );
    let list = headless(&api, &admin, "GET", "/api/keys?archived=true", None).await;
    assert_eq!(document(&list, 200)["keys"][0]["id"], id);
    let rotated = headless(
        &api,
        &admin,
        "POST",
        &format!("{key_uri}/rotate"),
        Some(json!({"revision":3})),
    )
    .await;
    error(&rotated, 409, "key_archived");
}

#[tokio::test]
async fn browser_ownership_and_callback_once_match_swift_http_contract() {
    let fixture = Fixture::new();
    let provider = Arc::new(Provider::default());
    let (admin, api) = management(&fixture, provider.clone());
    let (cookie, csrf) = login(&admin).await;
    let (other, _) = login(&admin).await;
    let begin = |csrf: &str| {
        request(
            "POST",
            "/api/accounts/authorization",
            Some(json!({"target": null, "method": "callback"})),
            &[
                ("host", HOST),
                ("origin", ORIGIN),
                ("cookie", &cookie),
                ("x-codexone-csrf", csrf),
            ],
        )
    };
    let refused = api
        .route(&admin, &begin("synthetic-wrong"), KeyOptions::default)
        .await
        .unwrap();
    error(&refused, 403, "invalid_csrf");
    let start = api
        .route(&admin, &begin(&csrf), KeyOptions::default)
        .await
        .unwrap();
    let start = document(&start, 200);
    let id = start["flowID"].as_str().unwrap();
    let state = start["authorizationURL"]
        .as_str()
        .unwrap()
        .split_once("state=")
        .unwrap()
        .1;
    let flow_uri = format!("/api/accounts/authorization/{id}");
    let status = |cookie| {
        request(
            "GET",
            &flow_uri,
            None,
            &[("host", HOST), ("cookie", cookie)],
        )
    };
    let wrong = api
        .route(&admin, &status(&other), KeyOptions::default)
        .await
        .unwrap();
    error(&wrong, 409, "account_conflict");
    let pending = api
        .route(&admin, &status(&cookie), KeyOptions::default)
        .await
        .unwrap();
    assert_eq!(document(&pending, 200)["status"], "pending");
    let body = json!({"callbackURL": format!("http://localhost:1455/auth/callback?state={state}&code=synthetic-code")});
    let wrong = headless(&api, &admin, "POST", &flow_uri, Some(body.clone())).await;
    error(&wrong, 409, "account_conflict");
    let complete = request(
        "POST",
        &flow_uri,
        Some(body),
        &[
            ("host", HOST),
            ("origin", ORIGIN),
            ("cookie", &cookie),
            ("x-codexone-csrf", &csrf),
        ],
    );
    let completed = api
        .route(&admin, &complete, KeyOptions::default)
        .await
        .unwrap();
    let account = document(&completed, 200)["account"].clone();
    let account_id = account["id"].as_str().unwrap();
    assert_eq!(
        account,
        json!({
            "id": account_id, "displayName": null, "revision": 1, "credentialVersion": 1, "mode": "disabled",
            "authorization": "ready", "createdAtUnixSeconds": NOW, "inFlight": 0,
            "accessExpiresAtUnixSeconds": NOW + 3600, "credentialUpdatedAtUnixSeconds": NOW,
        })
    );
    let again = api
        .route(&admin, &complete, KeyOptions::default)
        .await
        .unwrap();
    error(&again, 409, "account_conflict");
    assert_eq!(provider.callbacks.load(Ordering::SeqCst), 1);
    let persisted = api
        .route(&admin, &status(&cookie), KeyOptions::default)
        .await
        .unwrap();
    assert_eq!(document(&persisted, 200)["accountID"], account_id);
    let invalid_flow = api
        .route(&admin, &begin(&csrf), KeyOptions::default)
        .await
        .unwrap();
    let invalid_flow = document(&invalid_flow, 200);
    let invalid_uri = format!(
        "/api/accounts/authorization/{}",
        invalid_flow["flowID"].as_str().unwrap()
    );
    let invalid = request(
        "POST",
        &invalid_uri,
        Some(
            json!({"callbackURL":"http://localhost:1455/auth/callback?state=wrong&code=synthetic-code"}),
        ),
        &[
            ("host", HOST),
            ("origin", ORIGIN),
            ("cookie", &cookie),
            ("x-codexone-csrf", &csrf),
        ],
    );
    let rejected = api
        .route(&admin, &invalid, KeyOptions::default)
        .await
        .unwrap();
    error(&rejected, 400, "invalid_authorization_command");
    let status = request(
        "GET",
        &invalid_uri,
        None,
        &[("host", HOST), ("cookie", &cookie)],
    );
    let status = api
        .route(&admin, &status, KeyOptions::default)
        .await
        .unwrap();
    assert_eq!(document(&status, 200)["failureCode"], "verification_failed");
    let consumed = api
        .route(&admin, &invalid, KeyOptions::default)
        .await
        .unwrap();
    error(&consumed, 409, "account_conflict");
    assert_eq!(provider.callbacks.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn device_polling_is_bounded_and_cancellation_awaits_an_accepted_commit() {
    let fixture = Fixture::new();
    let provider = Arc::new(Provider::default());
    let (admin, api) = management(&fixture, provider.clone());
    let admin = Arc::new(admin);
    let begin = headless(
        &api,
        &admin,
        "POST",
        "/api/accounts/authorization",
        Some(json!({"target":null})),
    )
    .await;
    let begin = document(&begin, 200);
    assert_eq!(begin["method"], "device");
    assert_eq!(begin["intervalSeconds"], 3);
    assert!(begin.get("deviceAuthID").is_none());
    let uri = format!(
        "/api/accounts/authorization/{}",
        begin["flowID"].as_str().unwrap()
    );
    let pending = headless(&api, &admin, "GET", &uri, None).await;
    assert_eq!(document(&pending, 200)["userCode"], "SYNTH-CODE");
    let held = Arc::new(Hold {
        entered: Notify::new(),
        release: Notify::new(),
    });
    *fixture.writer.0.hold.lock().unwrap() = Some(held.clone());
    held.entered.notified().await;
    let discard = tokio::spawn({
        let api = api.clone();
        let admin = admin.clone();
        let uri = uri.clone();
        async move { headless(&api, &admin, "DELETE", &uri, None).await }
    });
    tokio::task::yield_now().await;
    assert!(!discard.is_finished());
    held.release.notify_one();
    assert_eq!(
        document(&discard.await.unwrap(), 200),
        json!({"discarded":true})
    );
    let gone = headless(&api, &admin, "GET", &uri, None).await;
    error(&gone, 409, "account_conflict");
    assert_eq!(provider.polls.load(Ordering::SeqCst), 3);
    assert_eq!(provider.exchanges.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.field::<i64>("SELECT COUNT(*) FROM accounts"), 1);

    let provider = Arc::new(Provider {
        no_response: true,
        ..Provider::default()
    });
    let (admin, api) = management(&fixture, provider.clone());
    let begin = headless(
        &api,
        &admin,
        "POST",
        "/api/accounts/authorization",
        Some(json!({"target":null})),
    )
    .await;
    let begin = document(&begin, 200);
    let uri = format!(
        "/api/accounts/authorization/{}",
        begin["flowID"].as_str().unwrap()
    );
    for _ in 0..6 {
        tokio::time::sleep(Duration::from_secs(3)).await;
        tokio::task::yield_now().await;
    }
    let failed = headless(&api, &admin, "GET", &uri, None).await;
    let failed = document(&failed, 200);
    assert_eq!(failed["status"], "failed");
    assert_eq!(failed["failureCode"], "authorization_failed");
    assert!(failed.get("userCode").is_none());
    assert_eq!(provider.polls.load(Ordering::SeqCst), 6);
    api.shutdown().await;
}

struct HangingRefresh(Arc<Notify>);

impl RefreshProvider for HangingRefresh {
    async fn refresh(
        &self,
        _credential: &AccountCredential,
        _namespace: &str,
    ) -> std::result::Result<VerifiedAuthorization, RefreshFailure> {
        self.0.notify_one();
        pending().await
    }
}

#[tokio::test]
async fn shutdown_settles_refresh_after_request_cancellation() {
    let fixture = Fixture::new();
    let account = fixture
        .governance
        .seal_verified(Target::Create, verified("synthetic/refresh"))
        .await
        .unwrap();
    let started = Arc::new(Notify::new());
    let service = Arc::new(RefreshService::new(
        fixture.governance.clone(),
        HangingRefresh(started.clone()),
    ));
    let started_refresh = tokio::spawn({
        let service = service.clone();
        async move { service.refresh_account(account.id, 1).await }
    });
    started.notified().await;
    started_refresh.abort();
    let _ = started_refresh.await;
    service.shutdown().await;
    assert_eq!(
        fixture.field::<String>("SELECT authorization FROM accounts"),
        "auth_uncertain"
    );
    assert_eq!(
        fixture.field::<String>("SELECT action FROM account_events WHERE revision=3"),
        "refresh_uncertain"
    );
}
