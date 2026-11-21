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
            "reservedMicros": 10, "upstreamTransport": "http"
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
            "principal": "synthetic-client", "models": ["synth-text"], "limits": {"tokens": null, "active": 2}
        })),
    );
    assert_eq!(status, 201, "{issued}");
    let key = issued["secret"].as_str().unwrap();
    let key_id = issued["key"]["id"].as_str().unwrap();
    let (status, models) = request(data, "GET", "/v1/models", Some(key), None);
    assert_eq!(status, 200);
    assert_eq!(models["data"].as_array().unwrap().len(), 1);
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

    process.terminate();
    stop.send(()).unwrap();
    worker.join().unwrap();
    assert_eq!(
        *recorded.lock().unwrap(),
        ["account-a", "account-a", "account-b"]
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
    assert_eq!(rows.len(), 3);
    for (index, (account, ledger_key, state, usage, outcome)) in rows.iter().enumerate() {
        assert_eq!(account, ["account-a", "account-a", "account-b"][index]);
        assert_eq!(ledger_key, key_id);
        let outcome: Value = serde_json::from_str(outcome).unwrap();
        if index == 1 {
            assert_eq!(outcome["failure"], "authentication_rejected");
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
        1
    );
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
    (status, serde_json::from_str(body).unwrap_or(Value::Null))
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
    assert!(head.starts_with("POST /backend-api/codex/responses "));
    let account = fields["chatgpt-account-id"];
    assert!(fields["authorization"].starts_with("Bearer ey"));
    let mut body = vec![0; fields["content-length"].parse().unwrap()];
    reader.read_exact(&mut body).unwrap();
    let request: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(request["stream"], true);
    assert_eq!(request["store"], false);
    assert_eq!(request["model"], "synth-text");
    let index = {
        let mut capture = capture.lock().unwrap();
        capture.push(account.to_owned());
        capture.len()
    };
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
