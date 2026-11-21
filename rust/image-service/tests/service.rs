use std::{
    collections::HashMap, fs, future::Future, os::unix::fs::PermissionsExt, path::Path,
    time::Duration,
};

use codexone_config::{Configuration, RuntimeConfiguration, Source};
use codexone_execution::{
    Completeness, ExecutionError, ExecutionService, Failure, Options, OutcomeKind,
    PriceCompleteness, Route, State,
};
use codexone_http_upstream::{Bytes, CancellationToken, HttpUpstream};
use codexone_image_service::{
    ExchangeContext, ImageOutput, ImageService, ImageSession, ServiceError, StaticImageTarget,
};
use http::{HeaderMap, Request};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
    time::timeout,
};

const KEY: &str = "synthetic-static-image-caller";
const UPSTREAM_TOKEN: &str = "synthetic-static-image-provider";
const GENERATIONS: &str = "/v1/images/generations";
const EDITS: &str = "/backend-api/codex/images/edits";
const NOW: i64 = 1_728_000_000;
const TEST_TIMEOUT: Duration = Duration::from_secs(5);

fn write_private(path: &Path, content: &str) {
    fs::write(path, content).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

fn configuration(directory: &Path, port: u16) -> Configuration {
    let identity = directory.join("identity.json");
    let token = directory.join("upstream-token");
    write_private(&token, UPSTREAM_TOKEN);
    write_private(
        &identity,
        &format!(
            r#"{{
            "principal":"synthetic-owner","keyID":"synthetic-key","keySHA256":"{:x}",
            "namespace":"synthetic-provider","identity":"synthetic-account",
            "upstreamBaseURL":"http://127.0.0.1:{port}/v1","upstreamTokenFile":"{}",
            "models":[{{"id":"synthetic-author","inputMicrosPerMillion":500000,"outputMicrosPerMillion":1000000}}],
            "imageGeneration":{{"defaultModel":"synthetic-image","models":[
                {{"id":"synthetic-image","inputMicrosPerMillion":2000000,"outputMicrosPerMillion":3000000}}
            ]}},
            "imageConcurrency":1,"reservedMicros":100,"executionTimeoutSeconds":4,
            "imageFirstResponseTimeoutSeconds":2,"progressTimeoutSeconds":3
        }}"#,
            Sha256::digest(KEY.as_bytes()),
            token.display(),
        ),
    );
    let env = HashMap::from([
        (
            "CODEXONE_DATA_DIRECTORY".into(),
            directory.to_str().unwrap().into(),
        ),
        (
            "CODEXONE_IDENTITY_CONFIG".into(),
            identity.to_str().unwrap().into(),
        ),
    ]);
    Configuration::load(RuntimeConfiguration::from_environment(&env).unwrap(), NOW).unwrap()
}

async fn services<'a>(
    directory: &Path,
    config: &'a Configuration,
) -> (ImageService<'a>, StaticImageTarget, ExecutionService) {
    let Some(Source::SingleIdentity(identity)) = &config.source else {
        panic!("expected static config")
    };
    let (target, policy) = StaticImageTarget::from_config(
        identity,
        "synthetic-policy".into(),
        "synthetic-prices".into(),
    )
    .unwrap();
    let database = directory.join("ledger.sqlite");
    Connection::open(&database)
        .unwrap()
        .execute_batch(include_str!("../../execution/tests/swift_v19.sql"))
        .unwrap();
    let worker = ExecutionService::open(
        database,
        Options::for_static_identity(policy).with_clock(|| NOW),
    )
    .await
    .unwrap();
    (
        ImageService::new(&identity.responses, HttpUpstream::default()).unwrap(),
        target,
        worker,
    )
}

fn request(path: &str, body: &'static str) -> Request<Bytes> {
    Request::post(path)
        .header("authorization", format!("Bearer {KEY}"))
        .header("content-type", "application/json")
        .header("chatgpt-account-id", "synthetic-inbound-account")
        .header("x-openai-actor-authorization", "synthetic-local-marker")
        .body(Bytes::from_static(body.as_bytes()))
        .unwrap()
}

fn context<'a>(
    id: &str,
    request: &'a Request<Bytes>,
    cancel: &'a CancellationToken,
) -> ExchangeContext<'a> {
    // Deliberately supply some raw headers as well to test the adapter's last-mile allowlist.
    ExchangeContext {
        attempt: id.into(),
        request_id: format!("request-{id}"),
        client_metadata: request.headers(),
        cancellation: cancel,
    }
}

async fn listener<F, Fut>(handler: F) -> (u16, JoinHandle<()>)
where
    F: FnOnce(TcpStream) -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (peer, _) = timeout(TEST_TIMEOUT, listener.accept())
            .await
            .unwrap()
            .unwrap();
        handler(peer).await;
        assert!(
            timeout(Duration::from_millis(60), listener.accept())
                .await
                .is_err(),
            "unexpected upstream replay"
        );
    });
    (port, server)
}

async fn receive(peer: &mut TcpStream, endpoint: &str) -> String {
    let mut reader = BufReader::new(peer);
    let mut first = String::new();
    reader.read_line(&mut first).await.unwrap();
    assert_eq!(
        first,
        format!("POST /backend-api/codex/images/{endpoint} HTTP/1.1\r\n")
    );
    let mut headers = HeaderMap::new();
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).await.unwrap(), 0);
        if line == "\r\n" {
            break;
        }
        let (name, value) = line.split_once(':').unwrap();
        headers.append(
            name.parse::<http::header::HeaderName>().unwrap(),
            value.trim().parse().unwrap(),
        );
    }
    assert_eq!(headers["authorization"], format!("Bearer {UPSTREAM_TOKEN}"));
    assert!(!headers.contains_key("chatgpt-account-id"));
    assert!(!headers.contains_key("x-openai-actor-authorization"));
    let mut body = vec![0; headers["content-length"].to_str().unwrap().parse().unwrap()];
    reader.read_exact(&mut body).await.unwrap();
    String::from_utf8(body).unwrap()
}

async fn reply(peer: &mut TcpStream, status: &str, content_type: &str, body: &str, extra: &str) {
    peer.write_all(format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nx-codex-imagegen-request-id: synthetic-image-id\r\n{extra}\r\n{body}",
        body.len(),
    ).as_bytes()).await.unwrap();
}

async fn drain(mut session: ImageSession<'_>, id: &str) -> Bytes {
    let Some(ImageOutput::Begin(headers)) = session.next().await.unwrap() else {
        panic!("missing response headers")
    };
    assert_eq!(headers["x-request-id"], format!("request-{id}"));
    assert_eq!(headers["x-codex-imagegen-request-id"], "synthetic-image-id");
    assert_eq!(headers["cache-control"], "no-store");
    let Some(ImageOutput::Body(body)) = session.next().await.unwrap() else {
        panic!("missing response body")
    };
    assert!(session.next().await.unwrap().is_none());
    session.finish().await.unwrap();
    body
}

#[tokio::test]
async fn static_config_routes_once_and_settles_native_and_svg_usage() {
    const BODY: &str = r#"{"created":1,"data":[{"b64_json":"PHN2Zy8+"}],"usage":{"input_tokens":3,"output_tokens":7,"input_tokens_details":{"text_tokens":2,"image_tokens":1}},"svg_usage":{"model":"synthetic-author","input_tokens":10,"output_tokens":20,"reasoning_tokens":4},"service_tier":"priority"}"#;
    let (port, server) = listener(|mut peer| async move {
        let body = receive(&mut peer, "generations").await;
        assert_eq!(
            body,
            r#"{"output_format":"svg","service_tier":"default","model":"synthetic-image"}"#
        );
        reply(&mut peer, "200 OK", "application/json", BODY, "").await;
    })
    .await;
    let dir = tempfile::tempdir().unwrap();
    let config = configuration(dir.path(), port);
    let (image, target, db) = services(dir.path(), &config).await;
    let cancel = CancellationToken::new();
    let call = request(
        GENERATIONS,
        r#"{"output_format":"svg","service_tier":"default"}"#,
    );
    let session = image
        .start_static(&db, &target, call.clone(), context("svg", &call, &cancel))
        .await
        .unwrap();
    assert_eq!(session.upstream_head().unwrap().0, 200);
    assert_eq!(db.snapshot("svg").await.unwrap().state, State::Intent);
    assert_eq!(drain(session, "svg").await, BODY);
    server.await.unwrap();

    let entry = db.snapshot("svg").await.unwrap();
    assert_eq!(entry.state, State::Settled);
    assert_eq!(entry.admission.requirements.unwrap().route, Route::Images);
    assert_eq!(entry.admission.model.as_deref(), Some("synthetic-image"));
    assert_eq!(entry.admission.service_tier.as_deref(), Some("default"));
    let outcome = entry.outcome.unwrap();
    assert_eq!(outcome.kind, OutcomeKind::Succeeded);
    assert_eq!(outcome.actual_service_tier.as_deref(), Some("priority"));
    assert!(outcome.first_event_milliseconds <= outcome.total_milliseconds);
    assert!(outcome.first_event_milliseconds.is_some());
    let usage = entry.usage.unwrap();
    assert_eq!(usage.native_images, Some(true));
    assert_eq!(
        (usage.input_tokens, usage.output_tokens, usage.cached_tokens),
        (0, 0, 0)
    );
    assert_eq!(
        (
            usage.images,
            usage.image_input_tokens,
            usage.image_output_tokens
        ),
        (1, Some(3), Some(7))
    );
    assert_eq!(
        (
            usage.image_input_text_tokens,
            usage.image_input_image_tokens
        ),
        (Some(2), Some(1))
    );
    assert_eq!(
        (
            usage.svg_input_tokens,
            usage.svg_output_tokens,
            usage.svg_reasoning_tokens
        ),
        (Some(10), Some(20), Some(4))
    );
    assert_eq!(usage.svg_author_model.as_deref(), Some("synthetic-author"));
    assert_eq!(usage.estimated_micros, 52);
    assert_eq!(usage.price_completeness, Some(PriceCompleteness::Complete));
    db.shutdown().await.unwrap();
}

#[tokio::test]
async fn capacity_and_permissions_precede_intent_and_drop_retains_backpressured_evidence() {
    let (port, server) = listener(|mut peer| async move {
        assert_eq!(receive(&mut peer, "generations").await, r#"{"model":"synthetic-image","stream":true}"#);
        let first = r#"{"type":"image_generation.completed","image_index":1,"created_at":1,"b64_json":"YQ==","usage":{"input_tokens":3,"output_tokens":7}}"#;
        let second = r#"{"type":"image_generation.completed","image_index":2,"created_at":1,"b64_json":"Yg==","usage":{"input_tokens":10,"output_tokens":20}}"#;
        // Keep the provider body open after two frames. Only the pulled frame should enter the ledger.
        peer.write_all(format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 10000\r\n\r\ndata: {first}\n\ndata: {second}\n\n",
        ).as_bytes()).await.unwrap();
        assert_eq!(timeout(TEST_TIMEOUT, peer.read(&mut [0])).await.unwrap().unwrap(), 0);
    }).await;
    let dir = tempfile::tempdir().unwrap();
    let config = configuration(dir.path(), port);
    let (image, target, db) = services(dir.path(), &config).await;
    let cancel = CancellationToken::new();
    let call = request(GENERATIONS, r#"{"model":"synthetic-image","stream":true}"#);
    let mut session = image
        .start_static(
            &db,
            &target,
            call.clone(),
            context("stream", &call, &cancel),
        )
        .await
        .unwrap();
    assert!(matches!(
        session.next().await.unwrap(),
        Some(ImageOutput::Begin(_))
    ));
    assert!(
        matches!(session.next().await.unwrap(), Some(ImageOutput::Body(frame)) if frame.windows(15).any(|x| x == b"\"image_index\":1"))
    );

    let mut duplicate = call.clone();
    duplicate.headers_mut().append(
        "authorization",
        "Bearer synthetic-untrusted".parse().unwrap(),
    );
    assert!(matches!(
        image
            .start_static(
                &db,
                &target,
                duplicate,
                context("wrong-key", &call, &cancel)
            )
            .await,
        Err(ServiceError::Execution(ExecutionError::Unauthorized))
    ));
    let wrong_model = request(GENERATIONS, r#"{"model":"synthetic-author"}"#);
    assert!(
        matches!(image.start_static(&db, &target, wrong_model, context("wrong-model", &call, &cancel)).await,
        Err(ServiceError::Image(error)) if error.status == 403)
    );

    let waiting = CancellationToken::new();
    let mut pending = Box::pin(image.start_static(
        &db,
        &target,
        call.clone(),
        context("waiting", &call, &waiting),
    ));
    assert!(
        timeout(Duration::from_millis(20), pending.as_mut())
            .await
            .is_err()
    );
    waiting.cancel();
    assert!(matches!(pending.await, Err(ServiceError::Image(error)) if error.cancelled));

    drop(session);
    server.await.unwrap();
    for id in ["wrong-key", "wrong-model", "waiting"] {
        assert_eq!(db.snapshot(id).await, Err(ExecutionError::UnknownAttempt));
    }
    let cancelled = db.snapshot("stream").await.unwrap();
    assert_eq!(cancelled.outcome.unwrap().kind, OutcomeKind::Cancelled);
    assert_eq!(cancelled.state, State::Unknown);
    let usage = cancelled.usage.unwrap();
    assert_eq!(usage.completeness, Completeness::Partial);
    assert_eq!(
        (
            usage.images,
            usage.image_input_tokens,
            usage.image_output_tokens
        ),
        (1, Some(3), Some(7))
    );
    db.shutdown().await.unwrap();
}

#[tokio::test]
async fn provider_rejection_and_unfinished_body_have_distinct_durable_evidence() {
    for refusal in [true, false] {
        let (port, server) = listener(move |mut peer| async move {
            receive(&mut peer, "edits").await;
            if refusal {
                reply(&mut peer, "429 Too Many Requests", "application/json", r#"{"error":{"code":"rate_limit_exceeded"}}"#, "Retry-After: 9\r\n").await;
            } else {
                peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{").await.unwrap();
                peer.shutdown().await.unwrap();
            }
        }).await;
        let dir = tempfile::tempdir().unwrap();
        let config = configuration(dir.path(), port);
        let (image, target, db) = services(dir.path(), &config).await;
        let cancel = CancellationToken::new();
        let call = request(EDITS, r#"{"model":"synthetic-image"}"#);
        let mut session = image
            .start_static(&db, &target, call.clone(), context("edit", &call, &cancel))
            .await
            .unwrap();
        let Err(error) = session.next().await else {
            panic!("expected provider failure")
        };
        if refusal {
            assert_eq!(error.status, 429);
            assert_eq!(error.retry_header().as_deref(), Some("9"));
            assert_eq!(
                session.response_headers()["x-codex-imagegen-request-id"],
                "synthetic-image-id"
            );
        }
        session.finish().await.unwrap();
        server.await.unwrap();

        let entry = db.snapshot("edit").await.unwrap();
        let outcome = entry.outcome.unwrap();
        if refusal {
            assert_eq!(entry.state, State::Settled);
            assert_eq!(outcome.failure, Some(Failure::RateLimited));
            assert_eq!(outcome.cooldown_seconds, Some(9));
            let usage = entry.usage.unwrap();
            assert_eq!(usage.provider_rejected_before_output, Some(true));
            assert_eq!(usage.estimated_micros, 0);
        } else {
            assert_eq!(entry.state, State::Unknown);
            assert_eq!(outcome.failure, Some(Failure::Indeterminate));
            assert!(entry.usage.is_none());
        }
        db.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn truncated_stream_after_completion_keeps_usage_and_failure() {
    let (port, server) = listener(|mut peer| async move {
        receive(&mut peer, "generations").await;
        let event = r#"{"type":"image_generation.completed","created_at":1,"b64_json":"YQ==","usage":{"input_tokens":3,"output_tokens":7}}"#;
        peer.write_all(format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 10000\r\n\r\ndata: {event}\n\n",
        ).as_bytes()).await.unwrap();
        peer.shutdown().await.unwrap();
    }).await;
    let dir = tempfile::tempdir().unwrap();
    let config = configuration(dir.path(), port);
    let (image, target, db) = services(dir.path(), &config).await;
    let cancel = CancellationToken::new();
    let call = request(GENERATIONS, r#"{"stream":true}"#);
    let mut session = image
        .start_static(
            &db,
            &target,
            call.clone(),
            context("truncated", &call, &cancel),
        )
        .await
        .unwrap();
    assert!(matches!(
        session.next().await.unwrap(),
        Some(ImageOutput::Begin(_))
    ));
    assert!(matches!(
        session.next().await.unwrap(),
        Some(ImageOutput::Body(_))
    ));
    assert!(session.next().await.is_err());
    // Dropping the writer while sending the replacement SSE error must preserve the provider failure.
    session.cancel().await.unwrap();
    server.await.unwrap();

    let entry = db.snapshot("truncated").await.unwrap();
    assert_eq!(entry.state, State::Settled);
    let outcome = entry.outcome.unwrap();
    assert_eq!(outcome.kind, OutcomeKind::Failed);
    assert_eq!(outcome.failure, Some(Failure::Indeterminate));
    let usage = entry.usage.unwrap();
    assert_eq!(usage.completeness, Completeness::Complete);
    assert_eq!((usage.images, usage.estimated_micros), (1, 27));
    db.shutdown().await.unwrap();
}
