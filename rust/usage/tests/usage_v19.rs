use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};

use bytes::Bytes;
use codexone_storage::Database;
use codexone_usage::{BusinessDay, Context, Error, OverviewSource, OverviewState, Reader, Usage};
use http::{Request, StatusCode};
use rusqlite::params;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::oneshot;

const DAY: i64 = 86_400;
const UTC: i64 = 20_000 * DAY;
const START: i64 = UTC - 8 * 3600;
const NOW: i64 = START + 1800;

struct Fixture {
    db: Database,
    _temp: TempDir,
}

impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let db = Database::open_or_create(temp.path().join("core.sqlite")).unwrap();
        Self { db, _temp: temp }
    }

    fn seed(&self) {
        let db = self.db.connection();
        for (id, archived) in [("key", None), ("archived", Some(START))] {
            let key = json!({"id": id, "principal": "synthetic", "displayName": "Test key",
                "enabled": archived.is_none(), "archivedAtUnixSeconds": archived});
            db.execute(
                "INSERT INTO managed_keys VALUES (?,?,?)",
                params![id, id, key.to_string()],
            )
            .unwrap();
        }
        db.execute("INSERT INTO health_models VALUES ('model')", [])
            .unwrap();
        for (id, at, state, closed, usage, outcome, rate) in [
            (
                "complete",
                Some(START),
                "settled",
                None,
                Some(
                    json!({"inputTokens": 18, "outputTokens": 8, "cachedTokens": 4,
                     "estimatedMicros": 11, "completeness": "complete"}),
                ),
                Some(
                    json!({"kind": "succeeded", "firstEventMilliseconds": 200, "totalMilliseconds": 500}),
                ),
                Some("16"),
            ),
            (
                "closed",
                Some(START + 5),
                "settled",
                Some(START + 100),
                Some(json!({"inputTokens": 12, "estimatedMicros": 5,
                    "completeness": "partial", "priceCompleteness": "partial",
                    "usageMissingReasons": ["output_tokens"]})),
                Some(
                    json!({"kind": "failed", "failure": "indeterminate", "firstEventMilliseconds": 100}),
                ),
                None,
            ),
            (
                "cancel",
                Some(START + 5),
                "unknown",
                None,
                None,
                Some(json!({"kind": "cancelled", "failure": "client_cancelled"})),
                None,
            ),
            (
                "inflight",
                Some(START + 6),
                "intent",
                None,
                None,
                None,
                None,
            ),
            ("old", None, "settled", None, None, None, None),
            (
                "image",
                Some(START + 9),
                "settled",
                None,
                Some(
                    json!({"nativeImages": true, "inputTokens": 10, "outputTokens": 10, "images": 2,
                    "completeness":"complete", "estimatedMicros": 99}),
                ),
                Some(json!({"kind": "succeeded"})),
                Some("901"),
            ),
            (
                "price-unavailable",
                Some(START + 10),
                "settled",
                None,
                Some(
                    json!({"inputTokens": 2, "outputTokens": 3, "estimatedMicros": 99,
                    "completeness": "complete", "priceCompleteness": "unavailable"}),
                ),
                Some(json!({"kind":"succeeded"})),
                Some("24"),
            ),
            (
                "outside",
                Some(START + DAY),
                "settled",
                None,
                None,
                None,
                None,
            ),
        ] {
            db.execute("INSERT INTO attempts(id,principal,key_id,namespace,identity,window_id,policy_version,pricing_version,
                    reserved,state,admission_json,created_at_epoch,outcome_json,usage_json,request_id,
                    closed_unknown_at_epoch,output_rate_settled_at,output_rate)
                    VALUES (?1,'synthetic','key','namespace','account','window','policy','pricing',
                    50,?2,?3,?4,?5,?6,?1,?7,?8,?9)",
                params![id, state, r#"{"model":"model","mode":"generation","reasoningEffort":"low","requestMetadataRecorded":true}"#,
                    at, outcome.map(|v| v.to_string()), usage.map(|v| v.to_string()),
                    closed, rate.map(|_| NOW - if id == "complete" { 5 } else { 2 }), rate]).unwrap();
        }
        for (id, at, reason) in [
            ("reject", START + 5, Some("reasoning_effort_not_allowed")),
            ("legacy", START + 5, None),
            ("expired", NOW - 30 * DAY - 1, None),
        ] {
            db.execute("INSERT INTO request_diagnostics(request_id,at_epoch,key_id,model,mode,failure,reason,reasoning_effort)
               VALUES (?1,?2,'key','model','generation','model_not_allowed',?3,'high')",
                params![id, at, reason]).unwrap();
        }
        db.execute("INSERT INTO usage_daily(day_epoch,key_id,model,mode,outcome,failure,completeness,usage_unknown,
                requests,last_used_epoch,input_tokens,output_tokens,estimated_micros,price_unknown) VALUES
                (?1,'key','model','generation','succeeded','','complete',0,3,?2,20,10,7,0)",
            params![UTC - DAY, START - 10]).unwrap();
    }

    fn reader(&self) -> Reader {
        Reader::open(self.db.path(), Duration::from_secs(1), || true).unwrap()
    }
}

fn request(path: &str) -> Request<Bytes> {
    Request::builder().uri(path).body(Bytes::new()).unwrap()
}

async fn fetch(usage: &Usage, path: &str, context: Arc<Context>) -> (StatusCode, Value) {
    let response = usage.route(&request(path), NOW, context).await.unwrap();
    assert_eq!(response.headers()["cache-control"], "no-store");
    (
        response.status(),
        serde_json::from_slice(response.body()).unwrap(),
    )
}

async fn get(usage: &Usage, path: &str) -> Value {
    let (status, result) = fetch(usage, path, Arc::default()).await;
    assert_eq!(status, StatusCode::OK, "{path}: {result}");
    result
}

#[tokio::test]
async fn history_window_pagination_and_rejections_preserve_public_semantics() {
    let fixture = Fixture::new();
    fixture.seed();
    let usage = Usage::new(fixture.reader(), BusinessDay::new(480).unwrap());
    let path = format!("/api/usage?start={START}&end={}&limit=5", START + DAY);
    let page = get(&usage, &path).await;
    assert_eq!(page["timezone"], "UTC+08:00");
    assert_eq!(page["totals"]["admitted"], 6);
    assert_eq!(page["totals"]["recordedRejections"], 2);
    assert_eq!(page["totals"]["cancelled"], 1);
    assert_eq!(page["totals"]["historicalWithoutTime"], 1);
    assert_eq!(page["totals"]["usageUnknown"], 2);
    assert_eq!(
        page["totals"]["unknownReasons"],
        json!({"client_cancelled":1,"indeterminate":1})
    );
    assert_eq!(page["totals"]["p95FirstEventMilliseconds"], 200);
    assert_eq!(page["totals"]["metrics"]["inputTokens"], "32");
    assert_eq!(page["totals"]["metrics"]["images"], "2");
    assert_eq!(page["totals"]["metrics"]["estimatedMicros"], "16");
    assert_eq!(page["totals"]["metrics"]["priceCompleteness"], "partial");
    assert_eq!(page["keyTokens"][0]["outputTokens"], "11");
    assert_eq!(page["buckets"].as_array().unwrap().len(), 24);
    assert_eq!(
        page["rows"][0]["metrics"]["priceCompleteness"],
        "unavailable"
    );
    assert_eq!(page["rows"][1]["metrics"]["inputTokens"], Value::Null);
    assert_eq!(page["rows"][3]["rejectionStage"], "validation");

    let cursor = page["nextCursor"].as_str().unwrap();
    let next = get(&usage, &format!("{path}&after={cursor}")).await;
    let ids: Vec<_> = next["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["closed", "cancel", "complete"]);
    assert_eq!(next["rows"][0]["state"], "closed_unknown");
    assert_eq!(next["rows"][0]["completeness"], Value::Null);
    assert_eq!(next["rows"][0]["metrics"]["inputTokens"], "12");
    assert_eq!(next["nextCursor"], Value::Null);

    let rejected = get(
        &usage,
        &format!("{path}&rejectedOnly=true&rejectionGroup=model_not_allowed:unrecorded"),
    )
    .await;
    assert_eq!(rejected["totals"]["admitted"], 0);
    assert_eq!(rejected["totals"]["recordedRejections"], 1);
    assert_eq!(rejected["lifetimeGovernance"]["exposureMicros"], "100");
    assert_eq!(
        rejected["rejectionCounts"],
        json!([{"failure":"model_not_allowed","reason":null,"count":1}])
    );

    for query in [
        "&key=a&key=b",
        "&nope=1",
        "&failedOnly=1",
        "&after=abc",
        "&rejectionGroup=model_not_allowed:unrecorded",
    ] {
        let (status, body) = fetch(&usage, &format!("{path}{query}"), Arc::default()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_command");
    }
}

#[tokio::test]
async fn summaries_include_rollups_and_publish_live_sections_with_freshness() {
    let fixture = Fixture::new();
    fixture.seed();
    let usage = Usage::new(fixture.reader(), BusinessDay::new(480).unwrap());
    let daily = get(&usage, "/api/usage/daily?days=3&key=key&model=model").await;
    assert_eq!(
        daily["buckets"][0]["metrics"]["priceCompleteness"],
        Value::Null
    );
    assert_eq!(daily["buckets"][1]["requests"], 3);
    assert_eq!(daily["buckets"][1]["metrics"]["estimatedMicros"], "7");
    assert_eq!(daily["buckets"][2]["atUnixSeconds"], START);
    assert_eq!(daily["buckets"][2]["requests"], 6);
    assert_eq!(daily["buckets"][2]["succeeded"], 3);
    assert_eq!(daily["buckets"][2]["cancelled"], 1);
    assert_eq!(daily["buckets"][2]["failures"]["client_cancelled"], 1);
    assert_eq!(daily["buckets"][2]["unknownReasons"]["client_cancelled"], 1);
    assert_eq!(daily["buckets"][2]["recordedRejections"], 2);
    assert_eq!(daily["buckets"][2]["metrics"]["estimatedMicros"], "16");
    assert_eq!(
        fetch(&usage, "/api/usage/daily?end=86400", Arc::default())
            .await
            .0,
        StatusCode::BAD_REQUEST
    );

    let keys = get(&usage, "/api/usage/keys?includeArchived=false").await;
    assert_eq!(keys["keys"].as_array().unwrap().len(), 1);
    let key = &keys["keys"][0];
    assert_eq!(key["tokens"], "73");
    assert_eq!(key["tokenBreakdown"], json!({"input":"52","output":"21"}));
    assert_eq!(key["firstUsedTodayAtUnixSeconds"], START);
    assert_eq!(key["lastUsedTodayAtUnixSeconds"], START + 10);
    assert_eq!(key["lastUsedAtUnixSeconds"], START + DAY);
    assert_eq!(key["estimatedMicros"], "16");
    assert_eq!(key["priceUsageIncomplete"], true);
    assert_eq!(key["tokenUsageIncomplete"], true);

    let clients = Arc::new(codexone_usage::DataClients::default());
    let mut revisions = clients.revision();
    let first = clients.register("key");
    let second = clients.register("key");
    revisions.changed().await.unwrap();
    let context = Arc::new(Context {
        clients: clients.snapshot(),
        live_output_after: Some(NOW - 3),
        first_events: [("inflight".into(), false)].into(),
        default_reasoning_efforts: [("model".into(), "low".into())].into(),
        ..Context::default()
    });
    let (status, options) = fetch(&usage, "/api/usage/options", context.clone()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(options["keyOptions"][0]["archived"], true);
    assert_eq!(options["models"], json!(["model"]));
    assert_eq!(options["defaultReasoningEfforts"], json!({"model":"low"}));
    let headroom = get(&usage, "/api/usage/headroom").await;
    assert_eq!(headroom["accounts"][0]["current"], 1);
    assert_eq!(headroom["unknownReconciliation"]["count"], 1);

    let mut state = OverviewState::new(NOW);
    let sample = usage.sample_overview(NOW, context.clone()).await;
    let updates = state.update_usage(NOW, sample).unwrap();
    let flight = &updates[&OverviewSource::InFlight]["data"];
    assert_eq!(flight["clients"][0]["keyID"], "key");
    assert_eq!(flight["clients"][0]["displayName"], "Test key");
    assert_eq!(flight["clients"][0]["count"], 2);
    drop(first);
    revisions.changed().await.unwrap();
    assert_eq!(clients.snapshot()[0].count, 1);
    drop(second);
    revisions.changed().await.unwrap();
    assert!(clients.snapshot().is_empty());
    assert_eq!(flight["rows"][0]["hasFirstEvent"], false);
    assert_eq!(flight["recentRequestOutputRateMedian"], 24.0);
    let mut shared_second = (*context).clone();
    shared_second.live_output_after = Some(NOW - 2);
    let historical = usage
        .sample_activity(NOW, Arc::new(shared_second.clone()))
        .await
        .unwrap();
    assert!(historical["recentRequestOutputRateMedian"].is_null());
    shared_second
        .live_output_attempts
        .insert("price-unavailable".into());
    let observed = usage
        .sample_activity(NOW, Arc::new(shared_second))
        .await
        .unwrap();
    assert_eq!(observed["recentRequestOutputRateMedian"], 24.0);
    assert_eq!(
        observed["requestOutputRateMediansByDay"],
        historical["requestOutputRateMediansByDay"]
    );
    assert_eq!(
        flight["requestOutputRateMediansByDay"][START.to_string()],
        20.0
    );
    assert_eq!(
        flight["requestOutputRateByHour"]["points"][START.to_string()],
        json!({"median":20.0,"count":2})
    );
    let snapshot = serde_json::to_value(state.snapshot()).unwrap();
    assert_eq!(snapshot.as_object().unwrap().len(), 8);
    assert_eq!(snapshot["system"]["freshness"], "unavailable");
    assert_eq!(snapshot["system"]["data"], Value::Null);

    let sample = usage.sample_overview(NOW, context).await.unwrap();
    let data = sample[&OverviewSource::Daily].clone();
    let metadata_only = state
        .update(NOW + 1, [(OverviewSource::Daily, data)].into())
        .unwrap();
    assert_eq!(metadata_only[&OverviewSource::Daily]["version"], 1);
    assert!(metadata_only[&OverviewSource::Daily].get("data").is_none());
    let failure = state.update_usage(NOW + 2, Err(Error::Capacity)).unwrap();
    assert_eq!(failure[&OverviewSource::Daily]["freshness"], "stale");
    assert_eq!(failure[&OverviewSource::Daily]["lastSuccessAt"], NOW + 1);
    assert_eq!(
        serde_json::to_value(state.snapshot()).unwrap()["daily"]["data"],
        snapshot["daily"]["data"]
    );
}

#[tokio::test]
async fn one_reader_keeps_a_snapshot_while_the_writer_commits() {
    let fixture = Fixture::new();
    let reader = fixture.reader();
    let (started_tx, started_rx) = oneshot::channel();
    let (resume_tx, resume_rx) = mpsc::channel();
    let task = tokio::spawn({
        let reader = reader.clone();
        async move {
            reader
                .read(move |tx| {
                    let before: i64 =
                        tx.query_row("SELECT COUNT(*) FROM health_models", [], |row| row.get(0))?;
                    assert!(
                        tx.execute("INSERT INTO health_models VALUES ('forbidden')", [])
                            .is_err()
                    );
                    started_tx.send(()).unwrap();
                    resume_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                    let after: i64 =
                        tx.query_row("SELECT COUNT(*) FROM health_models", [], |row| row.get(0))?;
                    Ok((before, after))
                })
                .await
        }
    });
    started_rx.await.unwrap();
    assert_eq!(reader.read(|_| Ok(())).await, Err(Error::Capacity));
    fixture
        .db
        .connection()
        .execute("INSERT INTO health_models VALUES ('written')", [])
        .unwrap();
    resume_tx.send(()).unwrap();
    assert_eq!(task.await.unwrap(), Ok((0, 0)));
    assert_eq!(
        reader
            .read(|tx| Ok(
                tx.query_row("SELECT COUNT(*) FROM health_models", [], |row| row
                    .get::<_, i64>(0))?
            ))
            .await,
        Ok(1)
    );
}

#[tokio::test]
async fn sqlite_cancellation_budget_and_storage_gate_release_the_reader() {
    const LONG: &str = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n";
    let fixture = Fixture::new();
    let timed = Reader::open(fixture.db.path(), Duration::from_millis(20), || true).unwrap();
    assert_eq!(
        timed
            .read(|tx| Ok(tx.query_row(LONG, [], |row| row.get::<_, i64>(0))?))
            .await,
        Err(Error::Capacity)
    );
    assert_eq!(timed.read(|_| Ok(())).await, Ok(()));

    let allowed = Arc::new(AtomicBool::new(true));
    let reader = Reader::open(fixture.db.path(), Duration::from_secs(5), {
        let allowed = allowed.clone();
        move || allowed.load(Ordering::Relaxed)
    })
    .unwrap();
    let (start_tx, start_rx) = oneshot::channel();
    let running = tokio::spawn({
        let reader = reader.clone();
        async move {
            reader
                .read(move |tx| {
                    start_tx.send(()).unwrap();
                    Ok(tx.query_row(LONG, [], |row| row.get::<_, i64>(0))?)
                })
                .await
        }
    });
    start_rx.await.unwrap();
    running.abort();
    assert!(running.await.unwrap_err().is_cancelled());
    // Cancellation has to drain the blocking job before capacity is released.
    tokio::time::timeout(Duration::from_secs(1), async {
        while reader.read(|_| Ok(())).await == Err(Error::Capacity) {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap();
    allowed.store(false, Ordering::Relaxed);
    assert_eq!(reader.read(|_| Ok(())).await, Err(Error::Capacity));
    allowed.store(true, Ordering::Relaxed);
    assert_eq!(reader.read(|_| Ok(())).await, Ok(()));
}

#[tokio::test]
async fn attention_preserves_missing_and_independently_unavailable_sources() {
    use codexone_usage::ProtocolExtensions;

    let fixture = Fixture::new();
    fixture.seed();
    let db = fixture.db.connection();
    db.execute(
        "INSERT INTO accounts VALUES ('account','namespace',1,1,'enabled',
         'auth_uncertain','synthetic-unused',NULL,?,'Synthetic account')",
        [NOW],
    )
    .unwrap();
    db.execute(
        "UPDATE managed_keys SET metadata_json=json_set(metadata_json,
          '$.expiresAtUnixSeconds',?,'$.policy.limits.tokens',50) WHERE id='key'",
        [NOW + DAY],
    )
    .unwrap();
    let usage = Usage::new(fixture.reader(), BusinessDay::new(480).unwrap());
    let storage = json!({
        "pressure": "normal", "coreAvailable": true, "optionalWorkAllowed": true,
        "sampledUnixSeconds": NOW,
        "backup": {"enabled": true, "enabledUnixSeconds": NOW - 73 * 3600,
            "totalBytes": 0, "largestBundleBytes": 800 * 1024 * 1024},
    });
    let context = Arc::new(Context {
        storage,
        daily_requests: Some(5),
        protocol_extensions: ProtocolExtensions {
            names: [("x-codex-synthetic".to_owned(), NOW)].into(),
            overflow: false,
        },
        ..Context::default()
    });
    let (status, report) = fetch(&usage, "/api/attention", context.clone()).await;
    assert_eq!(status, StatusCode::OK);
    let items = report["items"].as_array().unwrap();
    let item = |kind: &str| items.iter().find(|entry| entry["kind"] == kind).unwrap();
    assert_eq!(
        item("account_auth_uncertain")["subjectName"],
        "Synthetic account"
    );
    assert_eq!(item("quota_stale")["detail"]["reason"], "unavailable");
    assert_eq!(item("quota_stale")["sinceUnixSeconds"], Value::Null);
    assert_eq!(item("key_expiring")["sinceUnixSeconds"], NOW + DAY);
    assert_eq!(item("key_limit_near")["detail"]["usedPercent"], 146.0);
    assert_eq!(item("capacity_reference")["detail"]["exceeded"], true);
    assert_eq!(item("backup_stale")["severity"], "critical");
    assert_eq!(
        item("backup_size")["detail"]["largestBundleBytes"],
        800 * 1024 * 1024
    );
    assert_eq!(
        item("client_protocol_extension")["subjectName"],
        "x-codex-synthetic"
    );
    assert!(!items.iter().any(|entry| entry["kind"] == "quota_high"));

    db.execute(
        "INSERT INTO account_quota VALUES ('account',?)",
        [
            json!({"attemptedAtUnixSeconds": NOW, "observedAtUnixSeconds": NOW, "quota": {
                "limits": [{"id":"codex","primary":{"usedPercent":99.0}}],
            }})
            .to_string(),
        ],
    )
    .unwrap();
    db.execute(
        "INSERT INTO account_quota_priming VALUES ('account',?)",
        [json!({"attention":"model_removed","lastAttemptAt":NOW}).to_string()],
    )
    .unwrap();
    db.execute(
        "INSERT INTO account_reset_credits VALUES ('account',?)",
        [json!({"failures":4,"settings":{"retryCount":3},"lastFailureAt":NOW}).to_string()],
    )
    .unwrap();
    let (_, report) = fetch(&usage, "/api/attention", context.clone()).await;
    let items = report["items"].as_array().unwrap();
    let item = |kind: &str| items.iter().find(|entry| entry["kind"] == kind).unwrap();
    assert_eq!(item("quota_high")["detail"]["usedPercent"], 99.0);
    assert!(
        item("quota_high")["detail"]["keyRanking"]
            .as_str()
            .unwrap()
            .contains("$0.000016")
    );
    assert_eq!(item("quota_priming")["detail"]["code"], "model_removed");
    assert_eq!(item("reset_credits")["detail"]["code"], "repeated_failure");

    db.execute("UPDATE account_quota SET record_json='not-json'", [])
        .unwrap();
    let (_, report) = fetch(&usage, "/api/attention", context.clone()).await;
    let items = report["items"].as_array().unwrap();
    assert!(
        items
            .iter()
            .any(|entry| entry["kind"] == "attention_source_unavailable"
                && entry["detail"]["source"] == "accounts")
    );
    assert!(items.iter().any(|entry| entry["kind"] == "key_expiring"));

    let blocked = Arc::new(Context {
        storage: json!({"pressure":"blocked","coreAvailable":true,"optionalWorkAllowed":false}),
        ..Context::default()
    });
    let (_, report) = fetch(&usage, "/api/attention", blocked).await;
    let items = report["items"].as_array().unwrap();
    assert_eq!(items[0]["kind"], "storage_pressure");
    assert_eq!(
        items
            .iter()
            .filter(|entry| entry["kind"] == "attention_source_unavailable")
            .count(),
        3
    );
    assert!(items.iter().any(|entry| entry["kind"] == "backup_disabled"));
    assert_eq!(
        fetch(&usage, "/api/attention?unexpected=1", context)
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
}
