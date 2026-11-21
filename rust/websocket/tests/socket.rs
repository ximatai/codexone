use std::{
    future::{pending, ready},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use codexone_responses::{Contract, JsonValue, Mode, ProtocolError};
use codexone_websocket::{
    Admitted, BridgeEvidence, BridgeFailure, BridgeOptions, BridgeRoute, CancellationToken,
    ExecutionBudget, NativeApplication, NativeEnd, NativeEvidence, NativeFinish, NativeOptions,
    PreparedCreate, Socket, SocketEnd, UpstreamHandshake, WS_ROUTING_BYTES, bridge, bridge_route,
    create_frame, downstream_socket, native_frame, parse_create, serve_native, upgrade_response,
};
use futures_util::{SinkExt, StreamExt};
use http::{HeaderMap, HeaderValue, Request, StatusCode};
use tokio::{
    io::{DuplexStream, duplex},
    net::TcpListener,
    sync::mpsc,
    time::{Instant, timeout},
};
use tokio_tungstenite::{
    WebSocketStream, accept_async, accept_hdr_async,
    tungstenite::{
        Message, Utf8Bytes,
        handshake::server,
        protocol::{CloseFrame, Role, frame::coding::CloseCode},
    },
};

const TEST_TIMEOUT: Duration = Duration::from_secs(3);
const CREATE: &str = r#"{"type":"response.create","model":"synthetic-model","input":"check"}"#;
const COMPLETED: &str = r#"{"type":"response.completed","response":{"id":"resp_case","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}"#;

fn text(data: &str) -> Message {
    Message::Text(data.to_owned().into())
}

fn json(data: &str) -> JsonValue {
    JsonValue::decode(data.as_bytes()).unwrap()
}

async fn read<IO>(socket: &mut WebSocketStream<IO>) -> Message
where
    IO: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    timeout(TEST_TIMEOUT, socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
}

async fn read_json<IO>(socket: &mut WebSocketStream<IO>) -> JsonValue
where
    IO: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    json(read(socket).await.to_text().unwrap())
}

fn member<'a>(value: &'a JsonValue, key: &str) -> &'a str {
    value.get(key).and_then(JsonValue::as_str).unwrap()
}

#[test]
fn exact_upgrade_routes_ignore_extensions_and_refuse_subprotocols() {
    let build = |path: &str| {
        Request::builder()
            .uri(path)
            .header("Connection", "keep-alive, Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
            .header("Sec-WebSocket-Extensions", "permessage-deflate")
    };
    let request = build("/backend-api/codex/responses?a=1").body(()).unwrap();
    let response = upgrade_response(&request, true).unwrap().unwrap();
    assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
    assert_eq!(
        response.headers()["x-codex-websocket-max-message-bytes"],
        "12582912"
    );
    assert_eq!(
        response.headers()["sec-websocket-accept"],
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    );
    assert!(!response.headers().contains_key("sec-websocket-extensions"));
    assert!(upgrade_response(&request, false).unwrap().is_none());
    assert!(
        upgrade_response(&build("/v1/responses/").body(()).unwrap(), true)
            .unwrap()
            .is_none()
    );
    let request = build("/v1/responses")
        .header("sec-websocket-protocol", "unsupported")
        .body(())
        .unwrap();
    assert_eq!(upgrade_response(&request, true).unwrap_err().status, 400);
}

#[test]
fn create_preserves_order_and_projects_subscription_state_and_warmup() {
    let document = json(
        r#"{"type":"response.create","stream_id":"lane.1","model":"example","input":[],"generate":false,"client_metadata":{"extra":"allowed","ws_request_header_x_openai_internal_codex_responses_lite":"true"}}"#,
    );
    let request = parse_create(document, None, None).unwrap();
    assert_eq!(request.mode, Mode::Warmup);
    let encoded = create_frame(
        request,
        Contract::CodexSubscription,
        "lane.1",
        Some("state-1"),
    )
    .unwrap();
    let event = json(encoded.as_str());
    assert_eq!(event.get("generate"), Some(&JsonValue::Bool(false)));
    assert_eq!(event.get("stream"), Some(&JsonValue::Bool(true)));
    let metadata = event.get("client_metadata").unwrap();
    assert_eq!(member(metadata, "x-codex-turn-state"), "state-1");
    assert_eq!(member(metadata, "extra"), "allowed");
    let public = create_frame(
        parse_create(json(CREATE), None, None).unwrap(),
        Contract::Responses,
        "",
        None,
    )
    .unwrap();
    assert_eq!(
        public.as_str(),
        r#"{"model":"synthetic-model","input":"check","type":"response.create"}"#
    );
}

#[test]
fn routing_uses_inclusive_encoded_limit_and_protects_continuations() {
    let at = Utf8Bytes::from("x".repeat(WS_ROUTING_BYTES));
    let over = Utf8Bytes::from("x".repeat(WS_ROUTING_BYTES + 1));
    assert!(matches!(
        bridge_route(at, false),
        Ok(BridgeRoute::WebSocket(_))
    ));
    assert!(matches!(
        bridge_route(over.clone(), false),
        Ok(BridgeRoute::Http)
    ));
    assert_eq!(
        bridge_route(over, true).unwrap_err().code,
        "conversation_too_large"
    );
}

#[tokio::test]
async fn upstream_handshake_injects_credentials_and_never_follows_redirects() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/responses", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        #[allow(clippy::result_large_err)]
        // The tungstenite callback contract fixes this error type.
        let callback = |request: &server::Request, response: server::Response| {
            assert_eq!(request.uri().path(), "/responses");
            assert_eq!(
                request.headers()["authorization"],
                "Bearer synthetic-upstream"
            );
            assert_eq!(
                request.headers()["openai-beta"],
                "responses_websockets=2026-02-06"
            );
            assert!(!request.headers().contains_key("x-codex-turn-state"));
            assert!(!request.headers().contains_key("x-synthetic-hop"));
            Ok(response)
        };
        let mut socket = accept_hdr_async(socket, callback).await.unwrap();
        assert_eq!(read(&mut socket).await, text(CREATE));
    });
    let mut forwarded = HeaderMap::new();
    forwarded.insert(
        "authorization",
        HeaderValue::from_static("Bearer synthetic-downstream"),
    );
    forwarded.insert(
        "x-codex-turn-state",
        HeaderValue::from_static("synthetic-state"),
    );
    forwarded.insert("x-synthetic-hop", HeaderValue::from_static("ignored"));
    forwarded.insert("connection", HeaderValue::from_static("x-synthetic-hop"));
    let mut auth = HeaderMap::new();
    auth.insert(
        "authorization",
        HeaderValue::from_static("Bearer synthetic-upstream"),
    );
    let (mut upstream, _) = UpstreamHandshake::new(
        url.parse().unwrap(),
        Contract::CodexSubscription,
        &forwarded,
        &auth,
    )
    .unwrap()
    .connect_direct(Instant::now() + TEST_TIMEOUT, &CancellationToken::new())
    .await
    .unwrap();
    upstream.send(text(CREATE)).await.unwrap();
    timeout(TEST_TIMEOUT, server).await.unwrap().unwrap();

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/responses", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (mut io, _) = listener.accept().await.unwrap();
        let mut bytes = [0; 4096];
        assert_ne!(io.read(&mut bytes).await.unwrap(), 0);
        io.write_all(
            b"HTTP/1.1 302 Found\r\nlocation: ws://example.invalid/\r\ncontent-length: 0\r\n\r\n",
        )
        .await
        .unwrap();
    });
    let result = UpstreamHandshake::new(
        url.parse().unwrap(),
        Contract::Responses,
        &HeaderMap::new(),
        &HeaderMap::new(),
    )
    .unwrap()
    .connect_direct(Instant::now() + TEST_TIMEOUT, &CancellationToken::new())
    .await;
    assert!(
        matches!(result, Err(codexone_websocket::ConnectFailure::Rejected(failure)) if failure.upstream_status == Some(302))
    );
    timeout(TEST_TIMEOUT, server).await.unwrap().unwrap();
}

async fn provider_pair() -> (Socket, WebSocketStream<DuplexStream>) {
    let (client, provider) = duplex(64 * 1024);
    let handshake = UpstreamHandshake::new(
        "ws://synthetic.invalid/responses".parse().unwrap(),
        Contract::Responses,
        &HeaderMap::new(),
        &HeaderMap::new(),
    )
    .unwrap();
    let cancellation = CancellationToken::new();
    let (client, provider) = tokio::join!(
        handshake.connect_over(
            ready(Ok(client)),
            Instant::now() + TEST_TIMEOUT,
            &cancellation
        ),
        accept_async(provider),
    );
    (client.unwrap().0, provider.unwrap())
}

fn bridge_options(stream: bool) -> BridgeOptions {
    BridgeOptions {
        deadline: Instant::now() + TEST_TIMEOUT,
        budget: ExecutionBudget {
            total: TEST_TIMEOUT,
            first_response: Duration::from_secs(1),
            idle: Duration::from_secs(1),
        },
        stream,
        continuation: false,
        cancellation: CancellationToken::new(),
    }
}

#[tokio::test]
async fn bridge_delivers_terminal_before_immediate_eof_and_json_is_unwrapped() {
    let (upstream, mut provider) = provider_pair().await;
    let provider = tokio::spawn(async move {
        assert_eq!(read(&mut provider).await, text(CREATE));
        provider.send(text(COMPLETED)).await.unwrap();
    });
    let mut observations = Vec::new();
    let mut output = Vec::new();
    let result = bridge(
        ready(Ok(upstream)),
        CREATE.to_owned().into(),
        bridge_options(false),
        |event| {
            if let BridgeEvidence::Event(document) = event {
                observations.push(member(document, "type").to_owned());
            }
        },
        |event| {
            output.push(event);
            ready(Ok(()))
        },
    )
    .await;
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(observations, ["response.completed"]);
    assert_eq!(output.len(), 1);
    assert!(output[0].terminal);
    assert_eq!(member(&output[0].document, "id"), "resp_case");
    timeout(TEST_TIMEOUT, provider).await.unwrap().unwrap();
}

#[tokio::test]
async fn bridge_fallback_requires_unprocessed_explicit_1009() {
    for (event, code, expect_retry) in [
        (
            r#"{"type":"codex.rate_limits"}"#,
            Some(CloseCode::Size),
            true,
        ),
        (
            r#"{"type":"response.created","response":{"id":"resp_case"}}"#,
            Some(CloseCode::Size),
            false,
        ),
        (r#"{"type":"codex.rate_limits"}"#, None, false),
    ] {
        let (upstream, mut provider) = provider_pair().await;
        let server = tokio::spawn(async move {
            assert_eq!(read(&mut provider).await, text(CREATE));
            provider.send(text(event)).await.unwrap();
            if let Some(code) = code {
                provider
                    .close(Some(CloseFrame {
                        code,
                        reason: "synthetic".into(),
                    }))
                    .await
                    .unwrap();
            }
        });
        let mut output = Vec::new();
        let result = bridge(
            ready(Ok(upstream)),
            CREATE.to_owned().into(),
            bridge_options(true),
            |_| {},
            |event| {
                output.push(event);
                ready(Ok(()))
            },
        )
        .await;
        if expect_retry {
            assert!(
                matches!(
                    result,
                    Err(BridgeFailure::UnprocessedSizeRefusal {
                        http_fallback: true
                    })
                ),
                "{result:?}"
            );
            assert!(output.is_empty());
        } else {
            assert!(
                matches!(result, Err(BridgeFailure::Interrupted { .. })),
                "{result:?}"
            );
            assert_eq!(output.len(), 1);
        }
        timeout(TEST_TIMEOUT, server).await.unwrap().unwrap();
    }
}

#[tokio::test]
async fn bridge_cancel_during_upload_and_silent_upload_deadline() {
    let (upstream, _provider) = provider_pair().await;
    let mut options = bridge_options(true);
    options.deadline = Instant::now() + Duration::from_millis(100);
    let frame = Utf8Bytes::from("x".repeat(1024 * 1024));
    let result = bridge(
        ready(Ok(upstream)),
        frame,
        options,
        |_| {},
        |_| ready(Ok(())),
    )
    .await;
    assert!(
        matches!(result, Err(BridgeFailure::Interrupted { protocol, .. }) if protocol.code == "execution_deadline_exceeded"),
        "{result:?}"
    );

    let (upstream, _provider) = provider_pair().await;
    let options = bridge_options(true);
    let token = options.cancellation.clone();
    let operation = tokio::spawn(bridge(
        ready(Ok(upstream)),
        CREATE.to_owned().into(),
        options,
        |_| {},
        |_| ready(Ok(())),
    ));
    tokio::task::yield_now().await;
    token.cancel();
    let result = timeout(TEST_TIMEOUT, operation).await.unwrap().unwrap();
    assert!(matches!(
        result,
        Err(BridgeFailure::Interrupted {
            socket: Some(SocketEnd::Cancelled),
            ..
        } | BridgeFailure::BeforeSend(_))
    ));
}

#[derive(Default)]
struct TestApp {
    provider: Mutex<Option<mpsc::UnboundedSender<WebSocketStream<DuplexStream>>>>,
    admissions: AtomicUsize,
    connects: AtomicUsize,
    observations: Mutex<Vec<(usize, String)>>,
    finished: Mutex<Vec<(usize, NativeFinish)>>,
}

impl NativeApplication for TestApp {
    type Input = ();
    type Attempt = usize;
    type Identity = u8;

    fn prepare(
        &self,
        lane: &str,
        document: JsonValue,
    ) -> Result<PreparedCreate<()>, ProtocolError> {
        let request = parse_create(document, None, None)?;
        let warmup = request.mode == Mode::Warmup;
        Ok(PreparedCreate {
            admission: (),
            frame: native_frame(request, Contract::Responses, lane, None)?,
            warmup,
        })
    }

    async fn admit(
        &self,
        _: (),
        identity: Option<u8>,
        _: Instant,
    ) -> Result<Admitted<usize, u8>, ProtocolError> {
        let attempt = self.admissions.fetch_add(1, Ordering::Relaxed);
        Ok(Admitted {
            attempt,
            identity: identity.unwrap_or(7),
        })
    }

    async fn connect(
        &self,
        identity: &u8,
        _: Instant,
    ) -> Result<Socket, codexone_websocket::ConnectFailure> {
        assert_eq!(*identity, 7);
        self.connects.fetch_add(1, Ordering::Relaxed);
        let (client, server) = provider_pair().await;
        self.provider
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .send(server)
            .unwrap();
        Ok(client)
    }

    fn evidence(&self, attempt: &usize, evidence: NativeEvidence<'_>) {
        if let NativeEvidence::Event(document) = evidence {
            self.observations
                .lock()
                .unwrap()
                .push((*attempt, member(document, "type").to_owned()));
        }
    }

    async fn before_output(&self, _: &usize, _: &JsonValue) -> Result<(), ProtocolError> {
        Ok(())
    }

    fn finish(&self, attempt: usize, result: NativeFinish) {
        self.finished.lock().unwrap().push((attempt, result));
    }
}

async fn native_client(
    app: Arc<TestApp>,
) -> (
    WebSocketStream<DuplexStream>,
    mpsc::UnboundedReceiver<WebSocketStream<DuplexStream>>,
    tokio::task::JoinHandle<NativeEnd>,
) {
    let (tx, rx) = mpsc::unbounded_channel();
    *app.provider.lock().unwrap() = Some(tx);
    let (client, server) = duplex(64 * 1024);
    let client = WebSocketStream::from_raw_socket(client, Role::Client, None).await;
    let server = downstream_socket(server).await;
    let task = tokio::spawn(async move {
        serve_native(
            server,
            app.as_ref(),
            NativeOptions::default(),
            &CancellationToken::new(),
        )
        .await
    });
    (client, rx, task)
}

async fn provider_ready(
    receiver: &mut mpsc::UnboundedReceiver<WebSocketStream<DuplexStream>>,
) -> WebSocketStream<DuplexStream> {
    timeout(TEST_TIMEOUT, receiver.recv())
        .await
        .unwrap()
        .unwrap()
}

#[tokio::test]
async fn native_invalid_first_create_errors_without_connecting() {
    let app = Arc::new(TestApp::default());
    let (mut client, _provider, task) = native_client(app.clone()).await;
    client
        .send(text(
            r#"{"type":"response.create","stream_id":"lane","generate":null}"#,
        ))
        .await
        .unwrap();
    let error = read_json(&mut client).await;
    assert_eq!(member(&error, "type"), "error");
    assert!(error.get("stream_id").is_none());
    assert!(matches!(
        timeout(TEST_TIMEOUT, task).await.unwrap().unwrap(),
        NativeEnd::Protocol(_)
    ));
    assert_eq!(app.connects.load(Ordering::Relaxed), 0);
    assert_eq!(app.admissions.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn native_warmup_and_overlapping_lanes_preserve_fifo_and_late_controls() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut provider, task) = native_client(app.clone()).await;
    client
        .send(text(
            r#"{"type":"response.create","model":"example","generate":false,"input":[]}"#,
        ))
        .await
        .unwrap();
    let mut provider = provider_ready(&mut provider).await;
    assert_eq!(
        read_json(&mut provider).await.get("generate"),
        Some(&JsonValue::Bool(false))
    );
    provider.send(text(COMPLETED)).await.unwrap();
    assert_eq!(
        member(&read_json(&mut client).await, "type"),
        "response.completed"
    );

    for (lane, input) in [("alpha", "one"), ("alpha", "next"), ("beta", "parallel")] {
        client.send(text(&format!(r#"{{"type":"response.create","model":"example","stream_id":"{lane}","input":"{input}"}}"#))).await.unwrap();
    }
    let first = read_json(&mut provider).await;
    let parallel = read_json(&mut provider).await;
    assert_eq!(member(&first, "stream_id"), "alpha");
    assert_eq!(member(&first, "input"), "one");
    assert_eq!(member(&parallel, "stream_id"), "beta");

    provider
        .send(text(
            r#"{"type":"response.created","stream_id":"alpha","response":{"id":"resp_alpha"}}"#,
        ))
        .await
        .unwrap();
    assert_eq!(
        member(&read_json(&mut client).await, "type"),
        "response.created"
    );
    let interrupt = r#"{"type":"response.interrupt", "response_id":"resp_alpha"}"#;
    client.send(text(interrupt)).await.unwrap();
    assert_eq!(read(&mut provider).await, text(interrupt));
    client.send(text(interrupt)).await.unwrap();
    let sync_control = r#"{"type":"test.control"}"#;
    client.send(text(sync_control)).await.unwrap();
    assert_eq!(read(&mut provider).await, text(sync_control));

    provider
        .send(text(
            r#"{"type":"response.completed","response":{"id":"resp_alpha","status":"completed"}}"#,
        ))
        .await
        .unwrap();
    assert_eq!(member(&read_json(&mut client).await, "stream_id"), "alpha");
    let next = read_json(&mut provider).await;
    assert_eq!(member(&next, "input"), "next");
    provider
        .send(text(
            r#"{"type":"response.interrupt.accepted","response_id":"resp_alpha"}"#,
        ))
        .await
        .unwrap();
    let late = read_json(&mut client).await;
    assert_eq!(member(&late, "type"), "response.interrupt.accepted");
    assert_eq!(member(&late, "stream_id"), "alpha");

    provider
        .send(text(
            r#"{"type":"response.completed","stream_id":"alpha","response":{"id":"resp_next"}}"#,
        ))
        .await
        .unwrap();
    provider
        .send(text(
            r#"{"type":"response.completed","stream_id":"beta","response":{"id":"resp_beta"}}"#,
        ))
        .await
        .unwrap();
    assert_eq!(member(&read_json(&mut client).await, "stream_id"), "alpha");
    assert_eq!(member(&read_json(&mut client).await, "stream_id"), "beta");
    client.close(None).await.unwrap();
    assert!(matches!(
        timeout(TEST_TIMEOUT, task).await.unwrap().unwrap(),
        NativeEnd::Downstream(_)
    ));
    assert_eq!(app.connects.load(Ordering::Relaxed), 1);
    assert_eq!(app.finished.lock().unwrap().len(), 4);
    assert!(
        !app.observations
            .lock()
            .unwrap()
            .iter()
            .any(|(_, event)| event == "response.interrupt.accepted")
    );
}

#[tokio::test]
async fn native_disconnect_targets_late_identity_and_preserves_terminal_evidence() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut provider, task) = native_client(app.clone()).await;
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut provider).await;
    assert_eq!(
        member(&read_json(&mut provider).await, "type"),
        "response.create"
    );
    drop(client);
    provider
        .send(text(
            r#"{"type":"response.created","response":{"id":"resp_case"}}"#,
        ))
        .await
        .unwrap();
    let interrupt = read_json(&mut provider).await;
    assert_eq!(member(&interrupt, "type"), "response.interrupt");
    assert_eq!(member(&interrupt, "response_id"), "resp_case");
    provider.send(text(COMPLETED)).await.unwrap();
    assert!(matches!(
        timeout(TEST_TIMEOUT, task).await.unwrap().unwrap(),
        NativeEnd::Downstream(_)
    ));
    assert!(matches!(
        app.finished.lock().unwrap().as_slice(),
        [(
            _,
            NativeFinish::Terminal {
                client_cancelled: true
            }
        )]
    ));
    assert!(
        app.observations
            .lock()
            .unwrap()
            .iter()
            .any(|(_, event)| event == "response.completed")
    );
}

#[tokio::test]
async fn native_early_size_refusal_requires_new_create_and_keeps_fixed_identity() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut rx, task) = native_client(app.clone()).await;
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut rx).await;
    assert_eq!(
        member(&read_json(&mut provider).await, "type"),
        "response.create"
    );
    provider
        .close(Some(CloseFrame {
            code: CloseCode::Size,
            reason: Utf8Bytes::default(),
        }))
        .await
        .unwrap();
    assert_eq!(
        read_json(&mut client)
            .await
            .get("status")
            .and_then(JsonValue::as_i64),
        Some(413)
    );
    assert_eq!(app.connects.load(Ordering::Relaxed), 1);
    assert!(matches!(
        app.finished.lock().unwrap().as_slice(),
        [(_, NativeFinish::UnprocessedSizeRefusal)]
    ));

    client.send(text(r#"{"type":"response.create","model":"example","previous_response_id":"resp_old","input":[]}"#)).await.unwrap();
    assert_eq!(
        read_json(&mut client)
            .await
            .get("status")
            .and_then(JsonValue::as_i64),
        Some(409)
    );
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut rx).await;
    assert_eq!(
        member(&read_json(&mut provider).await, "type"),
        "response.create"
    );
    provider.send(text(COMPLETED)).await.unwrap();
    assert_eq!(
        member(&read_json(&mut client).await, "type"),
        "response.completed"
    );
    client.close(None).await.unwrap();
    timeout(TEST_TIMEOUT, task).await.unwrap().unwrap();
    assert_eq!(app.admissions.load(Ordering::Relaxed), 2);
}

#[tokio::test]
async fn cancellation_never_dispatches_while_connect_is_pending() {
    let token = CancellationToken::new();
    token.cancel();
    let result = bridge(
        pending(),
        CREATE.to_owned().into(),
        BridgeOptions {
            cancellation: token,
            ..bridge_options(true)
        },
        |_| {},
        |_| ready(Ok(())),
    )
    .await;
    assert!(matches!(
        result,
        Err(BridgeFailure::BeforeSend(
            codexone_websocket::ConnectFailure::Cancelled
        ))
    ));
}

#[tokio::test]
async fn fragmented_create_allows_interleaved_ping_and_reports_invalid_frames() {
    use tokio::io::AsyncWriteExt;
    use tokio_tungstenite::tungstenite::protocol::frame::{
        Frame,
        coding::{Data, OpCode},
    };
    let app = Arc::new(TestApp::default());
    let (mut client, mut rx, task) = native_client(app.clone()).await;
    let (first, second) = CREATE.split_at(24);
    client
        .send(Message::Frame(Frame::message(
            first,
            OpCode::Data(Data::Text),
            false,
        )))
        .await
        .unwrap();
    client
        .send(Message::Ping(b"check".as_slice().into()))
        .await
        .unwrap();
    assert_eq!(
        read(&mut client).await,
        Message::Pong(b"check".as_slice().into())
    );
    assert_eq!(app.admissions.load(Ordering::Relaxed), 0);
    client
        .send(Message::Frame(Frame::message(
            second,
            OpCode::Data(Data::Continue),
            true,
        )))
        .await
        .unwrap();
    let mut provider = provider_ready(&mut rx).await;
    assert_eq!(
        member(&read_json(&mut provider).await, "type"),
        "response.create"
    );
    provider.send(text(COMPLETED)).await.unwrap();
    assert_eq!(
        member(&read_json(&mut client).await, "type"),
        "response.completed"
    );

    // A client text frame without a mask is invalid after an otherwise valid exchange.
    client
        .get_mut()
        .write_all(&[0x81, 0x02, b'{', b'}'])
        .await
        .unwrap();
    assert!(matches!(
        timeout(TEST_TIMEOUT, task).await.unwrap().unwrap(),
        NativeEnd::Downstream(SocketEnd::InvalidFrame)
    ));
    assert_eq!(app.admissions.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn native_provider_error_is_sanitized_and_does_not_replace_socket() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut rx, task) = native_client(app.clone()).await;
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut rx).await;
    read(&mut provider).await;
    provider.send(text(r#"{"type":"error","status":429,"error":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"synthetic limit","headers":{"retry-after":"8","authorization":"synthetic-hidden"}}}"#)).await.unwrap();
    let error = read_json(&mut client).await;
    assert_eq!(member(&error, "type"), "error");
    assert_eq!(error.get("status").and_then(JsonValue::as_i64), Some(429));
    let headers = error
        .get("error")
        .and_then(|inner| inner.get("headers"))
        .or_else(|| error.get("headers"))
        .unwrap();
    assert_eq!(member(headers, "retry-after"), "8");
    assert!(headers.get("authorization").is_none());

    client.send(text(CREATE)).await.unwrap();
    read(&mut provider).await;
    provider.send(text(COMPLETED)).await.unwrap();
    assert_eq!(
        member(&read_json(&mut client).await, "type"),
        "response.completed"
    );
    client.close(None).await.unwrap();
    timeout(TEST_TIMEOUT, task).await.unwrap().unwrap();
    assert_eq!(app.connects.load(Ordering::Relaxed), 1);
    assert!(matches!(
        app.finished.lock().unwrap().as_slice(),
        [
            (_, NativeFinish::Provider { .. }),
            (_, NativeFinish::Terminal { .. }),
        ]
    ));
}

#[tokio::test]
async fn native_1009_with_multiple_dispatched_lanes_is_indeterminate() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut rx, task) = native_client(app.clone()).await;
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut rx).await;
    read(&mut provider).await;
    let second = r#"{"type":"response.create","model":"example","stream_id":"second","input":[]}"#;
    client.send(text(second)).await.unwrap();
    assert_eq!(
        member(&read_json(&mut provider).await, "stream_id"),
        "second"
    );
    provider
        .close(Some(CloseFrame {
            code: CloseCode::Size,
            reason: Utf8Bytes::default(),
        }))
        .await
        .unwrap();
    for _ in 0..2 {
        let error = read_json(&mut client).await;
        assert_eq!(error.get("status").and_then(JsonValue::as_i64), Some(502));
        assert_eq!(
            member(error.get("error").unwrap(), "code"),
            "execution_indeterminate"
        );
    }
    assert!(
        matches!(read(&mut client).await, Message::Close(Some(frame)) if frame.code == CloseCode::Normal)
    );
    assert!(matches!(
        timeout(TEST_TIMEOUT, task).await.unwrap().unwrap(),
        NativeEnd::Upstream(SocketEnd::Close(1009))
    ));
    assert!(
        app.finished
            .lock()
            .unwrap()
            .iter()
            .all(|(_, result)| matches!(result, NativeFinish::Indeterminate { .. }))
    );
}

#[tokio::test(start_paused = true)]
async fn saturated_lane_releases_queued_creates_without_admitting_them() {
    let app = Arc::new(TestApp::default());
    let (mut client, mut rx, task) = native_client(app.clone()).await;
    client.send(text(CREATE)).await.unwrap();
    let mut provider = provider_ready(&mut rx).await;
    read(&mut provider).await;
    for _ in 0..5 {
        client.send(text(CREATE)).await.unwrap();
    }
    let end = timeout(Duration::from_secs(7), task)
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(end, NativeEnd::Downstream(SocketEnd::Congested)));
    assert_eq!(app.admissions.load(Ordering::Relaxed), 1);
    assert_eq!(app.finished.lock().unwrap().len(), 1);
}
