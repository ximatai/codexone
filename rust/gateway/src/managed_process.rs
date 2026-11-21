use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    num::NonZeroU16,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use codexone_config::{Configuration, RuntimeConfiguration};
use codexone_storage::{
    AccountCredential, AccountCredentialCipher, AccountCredentialContext, Database,
};
use rusqlite::{Connection, OpenFlags, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tungstenite::{
    Message, WebSocket, accept_hdr, client, client::IntoClientRequest, handshake::server,
};

use crate::{gateway, managed::SubscriptionTarget, unix_time};

const ADMIN: &str = "synthetic-admin-secret-123456789";
const CLIENT: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const WAIT: Duration = Duration::from_secs(5);

#[test]
fn child() {
    let Ok(port) = std::env::var("CODEXONE_MANAGED_TEST_PORT") else {
        return;
    };
    let port: NonZeroU16 = port.parse().unwrap();
    let config =
        Configuration::load(RuntimeConfiguration::from_process().unwrap(), unix_time()).unwrap();
    let result = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(gateway::run_with_target(
            config,
            Some(SubscriptionTarget::synthetic_loopback(port, port)),
        ));
    assert!(result.is_ok());
}

#[test]
fn durable_pool_and_governance() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let state = root.join("state");
    fs::create_dir(&state).unwrap();
    let master = "66".repeat(32);
    private(&root.join("master"), &master);
    private(&root.join("admin"), ADMIN);
    private(
        &root.join("pool.json"),
        &json!({
            "models": (["synth-text", "synth-other"].map(|id| json!({
                "id": id, "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1,
            }))),
            "reservedMicros": 10, "upstreamTransport": "http",
            "imageGeneration": {"defaultModel":"synth-image", "models":[
                {"id":"synth-image", "inputMicrosPerMillion": 1, "outputMicrosPerMillion": 1}
            ]}
        })
        .to_string(),
    );
    let upstream = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    upstream.set_nonblocking(true).unwrap();
    let port = upstream.local_addr().unwrap().port();
    let path = state.join("core.sqlite");
    let now = unix_time();
    let cipher = AccountCredentialCipher::from_hex(&master, &[]).unwrap();
    let database = Database::open_or_create(&path).unwrap();
    for (id, mode, auth, intent) in [
        ("account-a", "enabled", "ready", None),
        ("account-b", "disabled", "ready", None),
        (
            "account-c",
            "disabled",
            "refreshing",
            Some("synthetic-refresh"),
        ),
    ] {
        seed_account(&database, &cipher, port, id, mode, auth, intent, now);
    }
    drop(database);

    let recorded = Arc::new(Mutex::new(Vec::new()));
    let capture = recorded.clone();
    let (stop, stopping) = mpsc::channel::<()>();
    let worker = thread::spawn(move || {
        while matches!(stopping.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            match upstream.accept() {
                Ok((socket, _)) => serve(socket, &capture),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("synthetic upstream: {error}"),
            }
        }
    });
    let (mut process, data, admin) = launch(root, port);
    assert_eq!(request(data, "GET", "/health/ready", None, None).0, 200);
    assert_eq!(request(admin, "GET", "/health/ready", None, None).0, 200);
    assert_eq!(request(admin, "GET", "/api/accounts", None, None).0, 401);
    let (status, accounts) = request(admin, "GET", "/api/accounts", Some(ADMIN), None);
    assert_eq!(status, 200);
    assert!(
        accounts["accounts"]
            .as_array()
            .unwrap()
            .iter()
            .any(|account| {
                account["id"] == "account-c" && account["authorization"] == "auth_uncertain"
            })
    );
    let (status, issued) = request(
        admin,
        "POST",
        "/api/keys",
        Some(ADMIN),
        Some(json!({
            "principal": "synthetic-client", "models": ["synth-text"], "limits": {"tokens": null, "active": 2},
            "imageGeneration": true, "imageModels": ["synth-image"]
        })),
    );
    assert_eq!(status, 201, "{issued}");
    let key = issued["secret"].as_str().unwrap();
    let key_id = issued["key"]["id"].as_str().unwrap();
    let (status, models) = request(data, "GET", "/v1/models", Some(key), None);
    assert_eq!(status, 200);
    assert_eq!(models["data"].as_array().unwrap().len(), 2);
    let denied = json!({"model": "synth-other", "input": "synthetic"});
    assert_eq!(
        request(data, "POST", "/v1/responses", Some(key), Some(denied)).0,
        403
    );
    let query = json!({"model": "synth-text", "input": "synthetic"});
    let (status, first) = request(
        data,
        "POST",
        "/v1/responses",
        Some(key),
        Some(query.clone()),
    );
    assert_eq!(status, 200, "{first}");
    assert_eq!(first["id"], "resp_synth_1");

    let continuation =
        json!({"model": "synth-text", "input": [{"type": "item_reference", "id": "msg_synth_1"}]});
    let (status, refused) = request(
        data,
        "POST",
        "/backend-api/codex/responses",
        Some(key),
        Some(continuation),
    );
    assert_eq!(status, 502, "{refused}");
    assert_eq!(refused["error"]["code"], "upstream_authentication_rejected");
    wait_for_health(data, 503);

    let (status, enabled) = request(
        admin,
        "PUT",
        "/api/accounts/account-b",
        Some(ADMIN),
        Some(json!({
            "mode": "enabled", "revision": 1,
        })),
    );
    assert_eq!(status, 200, "{enabled}");
    assert_eq!(request(admin, "GET", "/health/ready", None, None).0, 200);
    let (status, second) = request(data, "POST", "/v1/responses", Some(key), Some(query));
    assert_eq!(status, 200, "{second}");
    assert_eq!(second["id"], "resp_synth_3");

    let (status, image) = request(
        data,
        "POST",
        "/v1/images/generations",
        Some(key),
        Some(json!({"prompt": "synthetic"})),
    );
    assert_eq!(status, 200, "{image}");
    assert_eq!(image["data"].as_array().unwrap().len(), 1);

    let mut revision = enabled["account"]["revision"].as_i64().unwrap();
    for (index, (path, body)) in [
        (
            "/v1/responses",
            json!({"model": "synth-text", "input": "synthetic-hold"}),
        ),
        (
            "/backend-api/codex/images/edits",
            json!({"prompt": "synthetic-hold"}),
        ),
    ]
    .into_iter()
    .enumerate()
    {
        thread::scope(|scope| {
            let pending = scope.spawn(move || request(data, "POST", path, Some(key), Some(body)));
            let deadline = Instant::now() + WAIT;
            while recorded.lock().unwrap().len() < index + 5 {
                assert!(
                    Instant::now() < deadline,
                    "waiting for held loopback request"
                );
                thread::sleep(Duration::from_millis(10));
            }
            assert_eq!(active(admin), 1);
            let force = || {
                request(
                    admin,
                    "POST",
                    "/api/accounts/account-b/force-stop",
                    Some(ADMIN),
                    Some(json!({"revision": revision})),
                )
            };
            assert_eq!(force().0, 409);
            revision = mode(admin, "disabled", revision);
            let force = || {
                request(
                    admin,
                    "POST",
                    "/api/accounts/account-b/force-stop",
                    Some(ADMIN),
                    Some(json!({"revision": revision})),
                )
            };
            let (status, cancellation) = force();
            assert_eq!(status, 200, "{cancellation}");
            assert_eq!(cancellation["cancellationRequested"], 1);
            let (status, stopped) = pending.join().unwrap();
            assert_eq!(status, 503, "{stopped}");
            assert_eq!(stopped["error"]["code"], "account_force_stopped");
            let deadline = Instant::now() + WAIT;
            while active(admin) != 0 {
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(10));
            }
            assert_eq!(force().1["cancellationRequested"], 0);
            revision = mode(admin, "enabled", revision);
        });
    }

    let (status, revoked) = request(
        admin,
        "PUT",
        &format!("/api/keys/{key_id}"),
        Some(ADMIN),
        Some(
            json!({"revision": issued["key"]["revision"], "enabled": false, "models": ["synth-text"],
             "limits": {"tokens": null, "active": 2}}),
        ),
    );
    assert_eq!(status, 200, "{revoked}");
    assert_eq!(request(data, "GET", "/v1/models", Some(key), None).0, 401);

    process.terminate();
    stop.send(()).unwrap();
    worker.join().unwrap();
    assert_eq!(
        *recorded.lock().unwrap(),
        [
            "account-a",
            "account-a",
            "account-b",
            "account-b",
            "account-b",
            "account-b"
        ]
    );

    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        19
    );
    let mut query = db
        .prepare(
            "SELECT identity,key_id,state,usage_json,outcome_json FROM attempts ORDER BY rowid",
        )
        .unwrap();
    let rows: Vec<_> = query
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    assert_eq!(rows.len(), 6);
    for (index, (account, ledger_key, state, usage, outcome)) in rows.iter().enumerate() {
        assert_eq!(
            account,
            [
                "account-a",
                "account-a",
                "account-b",
                "account-b",
                "account-b",
                "account-b"
            ][index]
        );
        assert_eq!(ledger_key, key_id);
        let outcome: Value = serde_json::from_str(outcome).unwrap();
        if index == 1 {
            assert_eq!(outcome["failure"], "authentication_rejected");
        } else if index >= 4 {
            assert_eq!(state, "unknown");
            assert_eq!(outcome["failure"], "account_unavailable");
        } else if index == 3 {
            assert_eq!(state, "settled");
            assert_eq!(outcome["kind"], "succeeded");
            let usage: Value = serde_json::from_str(usage.as_ref().unwrap()).unwrap();
            assert_eq!(usage["imageInputTokens"], 2);
            assert_eq!(usage["imageOutputTokens"], 3);
        } else {
            assert_eq!(state, "settled");
            assert_eq!(outcome["kind"], "succeeded");
            let usage: Value = serde_json::from_str(usage.as_ref().unwrap()).unwrap();
            assert_eq!(usage["inputTokens"], 5);
            assert_eq!(usage["outputTokens"], 3);
        }
    }
    assert_eq!(
        db.query_row(
            "SELECT auth_rejected_version FROM account_health WHERE account_id='account-a'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM key_events WHERE key_id=?",
            [key_id],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        2
    );
}

fn seed_account(
    database: &Database,
    cipher: &AccountCredentialCipher,
    port: u16,
    id: &str,
    mode: &str,
    auth: &str,
    intent: Option<&str>,
    now: i64,
) {
    let namespace = namespace(id, port);
    let token = token(id, now + 7200);
    let credential = AccountCredential::new(
        token.clone(),
        "synthetic-refresh-token".into(),
        Some(token),
        now + 7200,
    )
    .unwrap();
    let context = AccountCredentialContext::new(id, &namespace, 1).unwrap();
    let sealed = cipher.seal(&credential, &context).unwrap();
    database
        .connection()
        .execute(
            "INSERT INTO accounts VALUES(?,?,1,1,?,?,?,?,?,NULL)",
            params![id, namespace, mode, auth, sealed, intent, now],
        )
        .unwrap();
}

fn active(admin: u16) -> u64 {
    let (status, accounts) = request(admin, "GET", "/api/accounts", Some(ADMIN), None);
    assert_eq!(status, 200, "{accounts}");
    accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|account| account["id"] == "account-b")
        .unwrap()["inFlight"]
        .as_u64()
        .unwrap()
}

fn mode(admin: u16, mode: &str, revision: i64) -> i64 {
    mode_for(admin, "account-b", mode, revision)
}

fn mode_for(admin: u16, account: &str, mode: &str, revision: i64) -> i64 {
    let (status, response) = request(
        admin,
        "PUT",
        &format!("/api/accounts/{account}"),
        Some(ADMIN),
        Some(json!({"revision": revision, "mode": mode})),
    );
    assert_eq!(status, 200, "{response}");
    response["account"]["revision"].as_i64().unwrap()
}

fn private(path: &Path, value: &str) {
    fs::write(path, value).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

fn namespace(id: &str, port: u16) -> String {
    let realm = format!("http://127.0.0.1:{port}");
    let scope = [
        "https://chatgpt.com/backend-api/codex",
        "codex-subscription",
        &realm,
        CLIENT,
        id,
        id,
    ];
    let encoded = serde_json::to_string(&scope).unwrap().replace('/', "\\/");
    format!("subscription-{:x}", Sha256::digest(encoded))
}

fn token(id: &str, expires: i64) -> String {
    let claims = json!({
        "iss": "https://auth.openai.com", "aud": CLIENT, "sub": id, "exp": expires,
        "https://api.openai.com/auth": {"chatgpt_account_id": id},
    });
    format!(
        "{}.{}.{}",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256"}"#),
        URL_SAFE_NO_PAD.encode(claims.to_string()),
        URL_SAFE_NO_PAD.encode(b"synthetic")
    )
}

struct Gateway(Child);

impl Gateway {
    fn terminate(&mut self) {
        assert!(
            Command::new("/bin/kill")
                .args(["-TERM", &self.0.id().to_string()])
                .status()
                .unwrap()
                .success()
        );
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(status) = self.0.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(Instant::now() < deadline, "gateway did not shut down");
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn launch(root: &Path, upstream: u16) -> (Gateway, u16, u16) {
    let mut gateway = Gateway(
        Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "managed_process::child", "--nocapture"])
            .env_clear()
            .env("CODEXONE_MANAGED_TEST_PORT", upstream.to_string())
            .env("CODEXONE_ACCOUNT_POOL_CONFIG", root.join("pool.json"))
            .env("CODEXONE_ACCOUNT_MASTER_KEY_FILE", root.join("master"))
            .env("CODEXONE_ADMIN_TOKEN_FILE", root.join("admin"))
            .env("CODEXONE_DATA_DIRECTORY", root.join("state"))
            .env("CODEXONE_DATA_PORT", "0")
            .env("CODEXONE_ADMIN_PORT", "0")
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let stdout = gateway.0.stdout.take().unwrap();
    let (report, lines) = mpsc::channel();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some((_, listening)) = line.split_once("LISTENING ") {
                let (plane, address) = listening.split_once(' ').unwrap();
                let (_, port) = address.rsplit_once(':').unwrap();
                if report
                    .send((plane.to_owned(), port.parse::<u16>().unwrap()))
                    .is_err()
                {
                    break;
                }
            }
        }
    });
    let mut ports = std::collections::HashMap::new();
    for _ in 0..2 {
        let (plane, port) = lines.recv_timeout(WAIT).unwrap();
        ports.insert(plane, port);
    }
    (gateway, ports["data"], ports["admin"])
}

fn request(
    port: u16,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
    let mut socket = TcpStream::connect(("127.0.0.1", port)).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let body = body.map_or_else(String::new, |body| body.to_string());
    let authorization = token.map_or_else(String::new, |token| {
        format!("Authorization: Bearer {token}\r\n")
    });
    write!(socket, "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n{authorization}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    let mut response = String::new();
    socket.read_to_string(&mut response).unwrap();
    let (head, body) = response.split_once("\r\n\r\n").unwrap();
    let status = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    let value = if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        let mut remaining = body;
        let mut bytes = Vec::new();
        loop {
            let (size, chunk) = remaining.split_once("\r\n").unwrap();
            let size = usize::from_str_radix(size, 16).unwrap();
            if size == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk.as_bytes()[..size]);
            remaining = &chunk[size + 2..];
        }
        serde_json::from_slice(&bytes).unwrap()
    } else {
        serde_json::from_str(body).unwrap_or(Value::Null)
    };
    (status, value)
}

fn wait_for_health(port: u16, wanted: u16) {
    let deadline = Instant::now() + WAIT;
    while request(port, "GET", "/health/ready", None, None).0 != wanted {
        assert!(
            Instant::now() < deadline,
            "pool readiness failed to converge"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn serve(mut socket: TcpStream, capture: &Mutex<Vec<String>>) {
    socket.set_nonblocking(false).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let mut reader = BufReader::new(&mut socket);
    let mut head = String::new();
    while !head.ends_with("\r\n\r\n") {
        assert_ne!(reader.read_line(&mut head).unwrap(), 0);
    }
    let fields: std::collections::HashMap<_, _> = head
        .lines()
        .filter_map(|line| line.split_once(": "))
        .map(|(name, value)| (name.to_ascii_lowercase(), value))
        .collect();
    if head.starts_with("GET /backend-api/wham/usage ") {
        write_response(&mut socket, "200 OK", "application/json", "{}");
        return;
    }
    let image = head.starts_with("POST /backend-api/codex/images/");
    assert!(image || head.starts_with("POST /backend-api/codex/responses "));
    let account = fields["chatgpt-account-id"];
    assert!(fields["authorization"].starts_with("Bearer ey"));
    let mut body = vec![0; fields["content-length"].parse().unwrap()];
    reader.read_exact(&mut body).unwrap();
    let request: Value = serde_json::from_slice(&body).unwrap();
    let index = {
        let mut capture = capture.lock().unwrap();
        capture.push(account.to_owned());
        capture.len()
    };
    if index >= 5 {
        assert!(if image {
            request["prompt"] == "synthetic-hold"
        } else {
            request["input"][0]["content"] == "synthetic-hold"
        });
        let mut end = [0];
        assert_eq!(
            reader.read(&mut end).unwrap(),
            0,
            "upstream did not close after force-stop"
        );
        return;
    }
    if image {
        assert_eq!(request["model"], "synth-image");
        let body = json!({"created": 1, "data": [
            {"b64_json":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg=="}
        ], "usage": {"input_tokens": 2, "output_tokens": 3, "input_tokens_details": {"text_tokens":1,"image_tokens":1}}});
        write_response(&mut socket, "200 OK", "application/json", &body.to_string());
        return;
    }
    assert_eq!(request["stream"], true);
    assert_eq!(request["store"], false);
    assert_eq!(request["model"], "synth-text");
    if index == 2 {
        assert_eq!(request["input"][0]["id"], "msg_synth_1");
        write_response(
            &mut socket,
            "401 Unauthorized",
            "application/json",
            r#"{"error":{"code":"synthetic"}}"#,
        );
        return;
    }
    let response = json!({
        "id": format!("resp_synth_{index}"), "object": "response", "status": "completed",
        "model": "synth-text", "output": [{"type": "message", "id": format!("msg_synth_{index}"), "role": "assistant", "content": []}],
        "usage": {"input_tokens": 5, "output_tokens": 3, "input_tokens_details": {"cached_tokens": 0}}
    });
    let created = json!({"type": "response.created", "response": {
        "id": response["id"], "status": "in_progress", "output": []
    }});
    let event = json!({"type": "response.completed", "response": response});
    let sse = format!("data: {created}\n\ndata: {event}\n\n");
    write_response(&mut socket, "200 OK", "text/event-stream", &sse);
}

fn write_response(socket: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    write!(socket, "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
}

#[test]
fn websocket_pool_keeps_connection_owner_and_force_stops_active_and_idle_work() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let state = root.join("state");
    fs::create_dir(&state).unwrap();
    let master = "66".repeat(32);
    private(&root.join("master"), &master);
    private(&root.join("admin"), ADMIN);
    private(
        &root.join("pool.json"),
        &json!({
            "models": [{"id": "synth-text", "inputMicrosPerMillion": 1000000,
                "outputMicrosPerMillion": 1000000}],
            "reservedMicros": 10, "upstreamTransport": "websocket",
        })
        .to_string(),
    );
    let upstream = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    upstream.set_nonblocking(true).unwrap();
    let port = upstream.local_addr().unwrap().port();
    let path = state.join("core.sqlite");
    let database = Database::open_or_create(&path).unwrap();
    let now = unix_time();
    let cipher = AccountCredentialCipher::from_hex(&master, &[]).unwrap();
    for (id, mode) in [("account-a", "enabled"), ("account-b", "disabled")] {
        seed_account(&database, &cipher, port, id, mode, "ready", None, now);
    }
    drop(database);

    let (report, requests) = mpsc::channel();
    let (stop, stopping) = mpsc::channel::<()>();
    let worker = thread::spawn(move || {
        let mut connections = Vec::new();
        while matches!(stopping.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            match upstream.accept() {
                Ok((socket, _)) => {
                    let report = report.clone();
                    let index = connections.len() + 1;
                    connections.push(thread::spawn(move || serve_ws(socket, index, report)));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("synthetic WebSocket upstream: {error}"),
            }
        }
        for connection in connections {
            connection.join().unwrap();
        }
    });
    let (mut process, data, admin) = launch(root, port);
    let (status, issued) = request(
        admin,
        "POST",
        "/api/keys",
        Some(ADMIN),
        Some(
            json!({"principal": "synthetic-client", "models": ["synth-text"],
            "limits": {"tokens": null, "active": 4}}),
        ),
    );
    assert_eq!(status, 201, "{issued}");
    let key = issued["secret"].as_str().unwrap();
    let mut active_socket = dial_ws(data, key);
    assert!(
        requests.try_recv().is_err(),
        "upgrade dispatched before a create"
    );
    ws_create(&mut active_socket, "initial", None);
    let first_event = ws_event(&mut active_socket);
    let initial = requests.recv_timeout(WAIT);
    assert_eq!(
        first_event["type"], "response.completed",
        "{first_event}, provider {initial:?}"
    );
    let initial = initial.unwrap();
    assert_eq!(initial, ("account-a".into(), "initial".into(), 1));
    let mut idle = dial_ws(data, key);
    ws_create(&mut idle, "idle", None);
    assert_eq!(ws_event(&mut idle)["type"], "response.completed");
    assert_eq!(
        requests.recv_timeout(WAIT).unwrap(),
        ("account-a".into(), "idle".into(), 2)
    );

    let revision_a = mode_for(admin, "account-a", "draining", 1);
    let revision_b = mode_for(admin, "account-b", "enabled", 1);
    let (status, bridged) = request(
        data,
        "POST",
        "/v1/responses",
        Some(key),
        Some(json!({"model": "synth-text", "input": "bridge"})),
    );
    assert_eq!(status, 200, "{bridged}");
    assert_eq!(
        requests.recv_timeout(WAIT).unwrap(),
        ("account-b".into(), "bridge".into(), 3)
    );

    ws_create(&mut active_socket, "pinned", Some("additional-lane"));
    assert_eq!(ws_event(&mut active_socket)["stream_id"], "additional-lane");
    assert_eq!(
        requests.recv_timeout(WAIT).unwrap(),
        ("account-a".into(), "pinned".into(), initial.2)
    );

    // This state came from a different pool account. A socket fixed to A cannot use it.
    let misrouted = json!({"type": "response.create", "model": "synth-text", "input": "misrouted",
        "client_metadata": {"x-codex-turn-state": "state-account-b"}});
    active_socket
        .send(Message::text(misrouted.to_string()))
        .unwrap();
    assert_eq!(
        ws_event(&mut active_socket)["error"]["code"],
        "continuation_owner_unavailable"
    );
    assert!(requests.try_recv().is_err());

    ws_create(&mut active_socket, "hold-native", None);
    assert_eq!(ws_event(&mut active_socket)["type"], "response.created");
    assert_eq!(
        requests.recv_timeout(WAIT).unwrap(),
        ("account-a".into(), "hold-native".into(), 1)
    );
    let revision_a = mode_for(admin, "account-a", "disabled", revision_a);
    assert_eq!(force(admin, "account-a", revision_a), 1);
    assert_eq!(
        ws_event(&mut active_socket)["error"]["code"],
        "account_force_stopped"
    );
    assert!(active_socket.read().unwrap().is_close());
    assert!(
        idle.read().unwrap().is_close(),
        "an idle fixed socket survived force-stop"
    );

    thread::scope(|scope| {
        let pending = scope.spawn(|| {
            request(
                data,
                "POST",
                "/v1/responses",
                Some(key),
                Some(json!({"model": "synth-text", "input": "hold-bridge"})),
            )
        });
        assert_eq!(
            requests.recv_timeout(WAIT).unwrap(),
            ("account-b".into(), "hold-bridge".into(), 4)
        );
        let disabled = mode_for(admin, "account-b", "disabled", revision_b);
        assert_eq!(force(admin, "account-b", disabled), 1);
        let (status, stopped) = pending.join().unwrap();
        assert_eq!(status, 503, "{stopped}");
        assert_eq!(stopped["error"]["code"], "account_force_stopped");
    });
    process.terminate();
    stop.send(()).unwrap();
    worker.join().unwrap();
    assert!(
        requests.try_recv().is_err(),
        "a stopped request was replayed"
    );
    let db = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let mut rows = db
        .prepare("SELECT identity, state, json_extract(outcome_json, '$.failure') FROM attempts ORDER BY rowid")
        .unwrap();
    assert_eq!(
        rows.query_map([], |row| Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?
        )))
        .unwrap()
        .map(Result::unwrap)
        .collect::<Vec<_>>(),
        [
            ("account-a".into(), "settled".into(), None),
            ("account-a".into(), "settled".into(), None),
            ("account-b".into(), "settled".into(), None),
            ("account-a".into(), "settled".into(), None),
            (
                "account-a".into(),
                "unknown".into(),
                Some("account_unavailable".into())
            ),
            (
                "account-b".into(),
                "unknown".into(),
                Some("account_unavailable".into())
            ),
        ]
    );
}

fn force(admin: u16, account: &str, revision: i64) -> u64 {
    let (status, response) = request(
        admin,
        "POST",
        &format!("/api/accounts/{account}/force-stop"),
        Some(ADMIN),
        Some(json!({"revision": revision})),
    );
    assert_eq!(status, 200, "{response}");
    response["cancellationRequested"].as_u64().unwrap()
}

fn dial_ws(port: u16, key: &str) -> WebSocket<TcpStream> {
    let socket = TcpStream::connect(("127.0.0.1", port)).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let mut request = format!("ws://127.0.0.1:{port}/backend-api/codex/responses")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {key}").parse().unwrap());
    client(request, socket).unwrap().0
}

fn ws_create(socket: &mut WebSocket<TcpStream>, prompt: &str, lane: Option<&str>) {
    let mut event = json!({"type": "response.create", "model": "synth-text", "input": prompt});
    if let Some(lane) = lane {
        event["stream_id"] = json!(lane);
    }
    socket.send(Message::text(event.to_string())).unwrap();
}

fn ws_event(socket: &mut WebSocket<TcpStream>) -> Value {
    serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap()
}

fn serve_ws(socket: TcpStream, index: usize, report: mpsc::Sender<(String, String, usize)>) {
    socket.set_nonblocking(false).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let mut account = String::new();
    let mut socket = accept_hdr(
        socket,
        |request: &server::Request, mut response: server::Response| {
            account = request.headers()["chatgpt-account-id"]
                .to_str()
                .unwrap()
                .to_owned();
            assert!(matches!(account.as_str(), "account-a" | "account-b"));
            assert!(
                request.headers()["authorization"]
                    .to_str()
                    .unwrap()
                    .starts_with("Bearer ey")
            );
            response.headers_mut().insert(
                "x-codex-turn-state",
                format!("state-{account}").parse().unwrap(),
            );
            Ok(response)
        },
    )
    .unwrap();
    let mut turn = 0;
    while let Ok(Message::Text(input)) = socket.read() {
        let event: Value = serde_json::from_str(input.as_str()).unwrap();
        assert_eq!(event["type"], "response.create");
        let prompt = event["input"][0]["content"].as_str().unwrap();
        report
            .send((account.clone(), prompt.into(), index))
            .unwrap();
        turn += 1;
        if prompt == "hold-bridge" {
            continue;
        }
        let held = prompt == "hold-native";
        let mut reply = json!({
            "type": if held { "response.created" } else { "response.completed" },
            "response": {
                "id": format!("resp_pool_{index}_{turn}"),
                "status": if held { "in_progress" } else { "completed" },
                "output": [],
                "usage": if held { Value::Null } else {
                    json!({"input_tokens": 5, "output_tokens": 3, "input_tokens_details": {"cached_tokens": 0}})
                }
            }
        });
        if let Some(lane) = event.get("stream_id") {
            reply["stream_id"] = lane.clone();
        }
        socket.send(Message::text(reply.to_string())).unwrap();
    }
}

#[test]
fn quota_management_and_http_priming_survive_gateway_restart() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let state = root.join("state");
    fs::create_dir(&state).unwrap();
    let master = "55".repeat(32);
    private(&root.join("master"), &master);
    private(&root.join("admin"), ADMIN);
    private(
        &root.join("pool.json"),
        &json!({
            "models": [{"id":"synth-text", "inputMicrosPerMillion":1, "outputMicrosPerMillion":1}],
            "reservedMicros":10, "upstreamTransport":"http"
        })
        .to_string(),
    );
    let upstream = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    upstream.set_nonblocking(true).unwrap();
    let port = upstream.local_addr().unwrap().port();
    let path = state.join("core.sqlite");
    let now = unix_time();
    let account = "synth-quota";
    let namespace = namespace(account, port);
    let access = token(account, now + 7200);
    let credential = AccountCredential::new(
        access.clone(),
        "synthetic-refresh".into(),
        Some(access),
        now + 7200,
    )
    .unwrap();
    let cipher = AccountCredentialCipher::from_hex(&master, &[]).unwrap();
    let sealed = cipher
        .seal(
            &credential,
            &AccountCredentialContext::new(account, &namespace, 1).unwrap(),
        )
        .unwrap();
    let db = Database::open_or_create(&path).unwrap();
    db.connection()
        .execute(
            "INSERT INTO accounts VALUES(?,?,1,1,'enabled','ready',?,NULL,?,NULL)",
            params![account, namespace, sealed, now],
        )
        .unwrap();
    drop(db);

    let (stop, stopping) = mpsc::channel::<()>();
    let (records, observed) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut consumed = Vec::new();
        while matches!(stopping.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            match upstream.accept() {
                Ok((socket, _)) => quota_upstream(socket, &mut consumed, &records),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("synthetic quota upstream: {error}"),
            }
        }
        consumed
    });
    let priming = "/api/accounts/synth-quota/quota-priming";
    let reset = "/api/accounts/synth-quota/reset-credits";
    let reset_status = format!("{reset}/state");
    let reset_consume = format!("{reset}/consume");
    let reset_settings = format!("{reset}/settings");
    let (mut gateway, data, admin) = launch(root, port);
    assert_eq!(request(admin, "GET", priming, None, None).0, 401);
    assert_eq!(request(data, "GET", priming, Some(ADMIN), None).0, 404);
    assert_eq!(
        request(
            admin,
            "GET",
            &format!("{priming}?unexpected=1"),
            Some(ADMIN),
            None
        )
        .0,
        400
    );
    let (status, list) = request(admin, "GET", reset, Some(ADMIN), None);
    assert_eq!(status, 200, "{list}");
    assert_eq!(list["credits"][0]["id"], "synth-card");
    let (status, saved) = request(
        admin,
        "PUT",
        &reset_settings,
        Some(ADMIN),
        Some(json!({
            "revision":list["state"]["revision"], "autoUseBeforeExpiry":false, "leadMinutes":10,"retryCount":2
        })),
    );
    assert_eq!(status, 200, "{saved}");
    assert_eq!(saved["settings"]["leadHours"], 1);
    let (status, result) = request(
        admin,
        "POST",
        &reset_consume,
        Some(ADMIN),
        Some(json!({"creditID":"synth-card"})),
    );
    assert_eq!(status, 200, "{result}");
    assert_eq!(result["code"], "unknown");
    assert_eq!(
        request(admin, "GET", &reset_status, Some(ADMIN), None).1["pending"],
        true
    );
    let (status, configured) = request(
        admin,
        "PUT",
        priming,
        Some(ADMIN),
        Some(json!({
            "revision":saved["revision"],"enabled":true,"model":null,"message":"start window"
        })),
    );
    assert_eq!(status, 200, "{configured}");
    assert_eq!(configured["defaultModel"], "synth-text");
    observed.recv_timeout(WAIT).unwrap();
    let deadline = Instant::now() + WAIT;
    loop {
        let (status, saved) = request(admin, "GET", priming, Some(ADMIN), None);
        assert_eq!(status, 200, "{saved}");
        if saved["lastResult"] == "success" {
            break;
        }
        assert!(Instant::now() < deadline, "priming did not settle: {saved}");
        thread::sleep(Duration::from_millis(10));
    }
    gateway.terminate();

    let (mut gateway, _, admin) = launch(root, port);
    assert_eq!(
        request(admin, "GET", priming, Some(ADMIN), None).1["lastResult"],
        "success"
    );
    let pending = request(admin, "GET", &reset_status, Some(ADMIN), None).1;
    assert_eq!(pending["pending"], true);
    assert_eq!(pending["pendingCreditID"], "synth-card");
    assert!(pending.get("requestID").is_none());
    assert_eq!(
        request(
            admin,
            "POST",
            &reset_consume,
            Some(ADMIN),
            Some(json!({"creditID":"synth-other"}))
        )
        .0,
        409
    );
    let (status, recovered) = request(admin, "POST", &reset_consume, Some(ADMIN), Some(json!({})));
    assert_eq!(status, 200, "{recovered}");
    assert_eq!(recovered["code"], "already_redeemed");
    gateway.terminate();
    stop.send(()).unwrap();
    let consumed = worker.join().unwrap();
    assert_eq!(consumed.len(), 2);
    assert_eq!(consumed[0], consumed[1]);
    assert!(
        observed.try_recv().is_err(),
        "priming crossed the window barrier"
    );
    let db = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let (mode, state, input): (String, String, i64) = db.query_row(
        "SELECT json_extract(admission_json,'$.mode'),state,json_extract(usage_json,'$.inputTokens') FROM attempts WHERE principal='internal:quota-priming'",
        [], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?))).unwrap();
    assert_eq!(
        (mode.as_str(), state.as_str(), input),
        ("priming", "settled", 5)
    );
}

fn quota_upstream(mut socket: TcpStream, consumed: &mut Vec<Value>, observed: &mpsc::Sender<()>) {
    socket.set_nonblocking(false).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let mut reader = BufReader::new(&mut socket);
    let mut head = String::new();
    while !head.ends_with("\r\n\r\n") {
        if reader.read_line(&mut head).unwrap() == 0 {
            return;
        }
    }
    let fields: std::collections::HashMap<_, _> = head
        .lines()
        .filter_map(|line| line.split_once(": "))
        .map(|(name, value)| (name.to_ascii_lowercase(), value))
        .collect();
    assert_eq!(fields["chatgpt-account-id"], "synth-quota");
    let path = head.split_ascii_whitespace().nth(1).unwrap();
    match path {
        "/backend-api/wham/usage" => {
            write_response(&mut socket, "200 OK", "application/json", &json!({
                "rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{
                    "used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":unix_time()+18000
                }}
            }).to_string());
        }
        "/backend-api/wham/rate-limit-reset-credits" => {
            write_response(&mut socket, "200 OK", "application/json", &json!({
                "available_count":1,"credits":[{"id":"synth-card","status":"available","reset_type":"quota","granted_at":"2026-01-01T00:00:00Z"}]
            }).to_string());
        }
        "/backend-api/wham/rate-limit-reset-credits/consume" | "/backend-api/codex/responses" => {
            let mut bytes = vec![0; fields["content-length"].parse().unwrap()];
            reader.read_exact(&mut bytes).unwrap();
            let body: Value = serde_json::from_slice(&bytes).unwrap();
            if path.ends_with("/consume") {
                assert_eq!(body["credit_id"], "synth-card");
                assert!(uuid::Uuid::parse_str(body["redeem_request_id"].as_str().unwrap()).is_ok());
                consumed.push(body);
                if consumed.len() > 1 {
                    write_response(
                        &mut socket,
                        "200 OK",
                        "application/json",
                        r#"{"code":"already_redeemed","windows_reset":0}"#,
                    );
                }
                return;
            }
            assert_eq!(body["input"][0]["content"], "start window");
            assert_eq!(body["tools"], json!([]));
            assert_eq!(body["store"], false);
            assert_eq!(body["stream"], true);
            assert!(fields["user-agent"].starts_with("codex_cli_rs/"));
            let completed = json!({"type":"response.completed","response":{
                "id":"resp_synth_priming","status":"completed","model":"synth-text","output":[],
                "usage":{"input_tokens":5,"output_tokens":3,"input_tokens_details":{"cached_tokens":0}}
            }});
            observed.send(()).unwrap();
            write_response(
                &mut socket,
                "200 OK",
                "text/event-stream",
                &format!("data: {completed}\n\n"),
            );
        }
        _ => panic!("unexpected synthetic route {path}"),
    }
}
