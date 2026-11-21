use std::path::{Path, PathBuf};

use codexone_execution::*;
use rusqlite::Connection;
use sha2::{Digest, Sha256};

const SECRET: &str = "synthetic-client-token-for-local-tests";
const ORIGIN: &str = "http://127.0.0.1:12345/v1";
const NOW: i64 = 1_728_000_000;
// SHA-256 of Swift JSONEncoder output for [ORIGIN, "responses", "synthetic-account", "synthetic"].
const NAMESPACE: &str =
    "synthetic-provider:e5f599a5e1154483034150f83e5425174dba35a5ddbac6eaa1511bbad41e0188";

fn policy(principal: &str, upstream_token: Option<&str>) -> StaticIdentity {
    StaticIdentity::new(
        StaticIdentityConfig {
            principal: principal.into(),
            key_id: "synthetic-key".into(),
            key_sha256: Sha256::digest(SECRET.as_bytes()).into(),
            namespace: "synthetic-provider".into(),
            identity: "synthetic-account".into(),
            upstream_base_url: ORIGIN.into(),
            models: vec!["synthetic-text".into()],
            vision_input: false,
            image_models: vec![],
            policy_version: "synthetic-policy".into(),
            pricing_version: "synthetic-prices".into(),
            reserved_micros: 10,
        },
        upstream_token,
    )
    .unwrap()
}

fn database(directory: &tempfile::TempDir) -> PathBuf {
    let path = directory.path().join("static.sqlite");
    let db = Connection::open(&path).unwrap();
    db.execute_batch(include_str!("swift_v19.sql")).unwrap();
    assert_empty_governance(&db);
    path
}

fn assert_empty_governance(db: &Connection) {
    let count: i64 = db
        .query_row(
            "SELECT (SELECT COUNT(*) FROM managed_keys) + (SELECT COUNT(*) FROM accounts)
              + (SELECT COUNT(*) FROM key_events) + (SELECT COUNT(*) FROM account_events)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

async fn open(path: &Path, policy: StaticIdentity, now: i64) -> ExecutionService {
    ExecutionService::open(
        path,
        Options::for_static_identity(policy).with_clock(move || now),
    )
    .await
    .unwrap()
}

fn authenticate(service: &ExecutionService) -> StaticAuthorization {
    service
        .authenticate_static(&[&format!("Bearer {SECRET}")])
        .unwrap()
}

fn response(id: &str) -> ObjectBinding {
    ObjectBinding {
        kind: "response".into(),
        raw_id: id.into(),
    }
}

fn request(attempt: &str, previous_response_id: Option<&str>) -> StaticAdmissionRequest {
    StaticAdmissionRequest {
        attempt: attempt.into(),
        request_id: Some(format!("request-{attempt}")),
        model: "synthetic-text".into(),
        mode: Mode::Generation,
        requirements: Requirements::default(),
        references: previous_response_id.into_iter().map(response).collect(),
        reasoning_effort: None,
        service_tier: None,
    }
}

async fn finish(mut execution: Execution, response_id: &str, input_tokens: i64, now: i64) {
    execution.begin_dispatch().unwrap();
    execution
        .observe(UsageEvidence {
            revision: 0,
            input_tokens,
            output_tokens: 3,
            estimated_micros: input_tokens + 3,
            completeness: Completeness::Complete,
            ..UsageEvidence::default()
        })
        .unwrap();
    execution.bind(&[response(response_id)]).await.unwrap();
    execution.finish(Some(Outcome::new(None, now))).unwrap();
}

#[tokio::test]
async fn static_first_turn_and_restart_previous_response_id_settle_in_swift_v19() {
    let directory = tempfile::tempdir().unwrap();
    let path = database(&directory);
    let config = policy("synthetic-principal", None);
    assert_eq!(config.owner().namespace, NAMESPACE);
    let first = open(&path, config, NOW).await;
    let authorization = authenticate(&first);

    let bearer = format!("Bearer {SECRET}");
    for headers in [
        vec![],
        vec!["Bearer synthetic-wrong-client-token"],
        vec![bearer.as_str(), bearer.as_str()],
    ] {
        assert_eq!(
            first.authenticate_static(&headers).err(),
            Some(ExecutionError::Unauthorized)
        );
    }
    assert_eq!(
        first.authenticate(&[bearer.as_str()]).await.err(),
        Some(ExecutionError::Unauthorized)
    );
    assert_eq!(
        first.account_credential().await.err(),
        Some(ExecutionError::AccountUnavailable)
    );

    let mut denied = request("denied-model", None);
    denied.model = "other-model".into();
    assert_eq!(
        first.admit_static(&authorization, denied).await.err(),
        Some(ExecutionError::Unauthorized)
    );
    let mut denied = request("denied-vision", None);
    denied.requirements.vision_input = true;
    assert_eq!(
        first.admit_static(&authorization, denied).await.err(),
        Some(ExecutionError::Unauthorized)
    );
    let mut denied = request("denied-tool", None);
    denied.requirements.image_model = Some("unknown-image".into());
    assert_eq!(
        first.admit_static(&authorization, denied).await.err(),
        Some(ExecutionError::Unauthorized)
    );

    let execution = first
        .admit_static(&authorization, request("first", None))
        .await
        .unwrap();
    assert_eq!(execution.admission().account_snapshot, None);
    assert_eq!(execution.admission().key_revision, None);
    assert_eq!(execution.admission().reserved_micros, 10);
    assert_eq!(execution.admission().pricing_version, "synthetic-prices");
    assert_eq!(first.snapshot("first").await.unwrap().state, State::Intent);
    finish(execution, "resp_first", 5, NOW).await;
    first.shutdown().await.unwrap();

    let foreign = open(&path, policy("other-principal", None), NOW + 1).await;
    let foreign_auth = authenticate(&foreign);
    assert_eq!(
        foreign
            .admit_static(&foreign_auth, request("foreign", Some("resp_first")))
            .await
            .err(),
        Some(ExecutionError::UnknownObject)
    );
    foreign.shutdown().await.unwrap();

    let changed_credential = policy("synthetic-principal", Some("a/b+c=="));
    assert_eq!(
        changed_credential.owner().namespace,
        "synthetic-provider:fd0ca581c445c47087c277b5f5f77176176aac7239abac1ad272571847bfca2c"
    );
    let changed = open(&path, changed_credential, NOW + 2).await;
    assert_eq!(
        changed
            .admit_static(
                &authenticate(&changed),
                request("changed-scope", Some("resp_first"))
            )
            .await
            .err(),
        Some(ExecutionError::UnknownObject)
    );
    changed.shutdown().await.unwrap();

    let second = open(&path, policy("synthetic-principal", None), NOW + 3).await;
    let continuation = request("second", Some("resp_first"));
    assert_eq!(
        second
            .admit_static(&authorization, continuation.clone())
            .await
            .err(),
        Some(ExecutionError::Unauthorized)
    );
    let execution = second
        .admit_static(&authenticate(&second), continuation)
        .await
        .unwrap();
    assert_eq!(
        execution.admission().references.as_deref(),
        Some([response("resp_first")].as_slice())
    );
    finish(execution, "resp_second", 7, NOW + 3).await;
    second.shutdown().await.unwrap();

    let db = Connection::open(&path).unwrap();
    assert_empty_governance(&db);
    let mut query = db
        .prepare(
            "SELECT id,state,estimated,json_extract(usage_json,'$.inputTokens'),
         json_extract(usage_json,'$.outputTokens'),json_extract(usage_json,'$.completeness')
         FROM attempts ORDER BY id",
        )
        .unwrap();
    let rows: Vec<(String, String, i64, i64, i64, String)> = query
        .query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert_eq!(
        rows,
        [
            ("first".into(), "settled".into(), 8, 5, 3, "complete".into()),
            (
                "second".into(),
                "settled".into(),
                10,
                7,
                3,
                "complete".into()
            ),
        ]
    );
    let binding_count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM bindings WHERE principal='synthetic-principal' AND namespace=?1",
            [NAMESPACE],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(binding_count, 2);
}

#[tokio::test]
async fn static_dispatched_intent_survives_an_unhanded_shutdown() {
    let directory = tempfile::tempdir().unwrap();
    let path = database(&directory);
    let service = open(&path, policy("synthetic-principal", None), NOW).await;
    let mut execution = service
        .admit_static(&authenticate(&service), request("interrupted", None))
        .await
        .unwrap();
    execution.begin_dispatch().unwrap();
    service.force_shutdown().await.unwrap();
    assert_eq!(execution.cancel(NOW), Err(ExecutionError::Closed));

    let reopened = open(&path, policy("synthetic-principal", None), NOW + 10).await;
    let row = reopened.snapshot("interrupted").await.unwrap();
    assert_eq!(row.state, State::Unknown);
    assert_eq!(row.unknown_since, Some(NOW + 10));
    assert_eq!(row.admission.reserved_micros, 10);
    assert_eq!(row.usage, None);
    assert_eq!(row.outcome, None);
    assert_eq!(
        reopened
            .admit_static(&authenticate(&reopened), request("interrupted", None))
            .await
            .err(),
        Some(ExecutionError::Conflict)
    );
    reopened.shutdown().await.unwrap();
    assert_empty_governance(&Connection::open(&path).unwrap());
}
