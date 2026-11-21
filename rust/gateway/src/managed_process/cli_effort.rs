use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use tungstenite::protocol::{CloseFrame, frame::coding::CloseCode};

const MODEL: &str = "synth-effort";
const RESPONSES: &str = "/backend-api/codex/responses";
const COMPACT: &str = "/backend-api/codex/responses/compact";

#[derive(Debug)]
struct Dispatch {
    socket: Option<usize>,
    body: Value,
}

struct Scenario<'a> {
    secret: &'a str,
    reports: mpsc::Receiver<Dispatch>,
    accepted: Vec<(String, &'static str, &'static str)>,
    denied: Vec<String>,
}

fn input(efforts: &[&str]) -> Value {
    let mut items = vec![json!({"type": "message", "role": "user", "content": "Synthetic turn."})];
    items.extend(
        efforts
            .iter()
            .map(|effort| json!({"type": "configuration_update", "reasoning": {"effort": effort}})),
    );
    json!(items)
}

fn body(input: Value) -> Value {
    json!({"model": MODEL, "reasoning": {"effort": "low"}, "input": input})
}

fn create(input: Value, lane: &str) -> Value {
    let mut body = body(input);
    body["type"] = json!("response.create");
    body["stream_id"] = json!(lane);
    body
}

fn continuation(lane: &str, id: &str) -> Value {
    let mut frame = create(input(&[]), lane);
    frame["previous_response_id"] = json!(id);
    frame
}

fn turn(socket: &mut WebSocket<TcpStream>, frame: &Value) -> Value {
    socket.send(Message::text(frame.to_string())).unwrap();
    ws_event(socket)
}

impl Scenario<'_> {
    fn seen(&self, expected: &Value, socket: Option<usize>) {
        let dispatch = self.reports.recv_timeout(WAIT).unwrap();
        assert_eq!(dispatch.socket, socket, "{dispatch:?}");
        for field in [
            "model",
            "reasoning",
            "input",
            "stream_id",
            "previous_response_id",
        ] {
            assert_eq!(dispatch.body.get(field), expected.get(field), "{field}");
        }
    }

    fn allow_ws(
        &mut self,
        socket: &mut WebSocket<TcpStream>,
        provider: usize,
        frame: &Value,
        mode: &'static str,
    ) -> String {
        let terminal = turn(socket, frame);
        assert_eq!(terminal["type"], "response.completed", "{terminal}");
        assert_eq!(terminal["stream_id"], frame["stream_id"]);
        self.seen(frame, Some(provider));
        let id = terminal["response"]["id"].as_str().unwrap().to_owned();
        self.accepted.push((id.clone(), "response", mode));
        id
    }

    fn allow_http(
        &mut self,
        port: u16,
        path: &str,
        frame: &Value,
        provider: Option<usize>,
    ) -> Value {
        let (status, response) =
            request(port, "POST", path, Some(self.secret), Some(frame.clone()));
        assert_eq!(status, 200, "{response}");
        self.seen(frame, provider);
        let (kind, mode) = if path == COMPACT {
            assert_eq!(response["object"], "response.compaction");
            ("compaction", "compact")
        } else {
            assert_eq!(response["status"], "completed");
            ("response", "generation")
        };
        let id = response["id"].as_str().unwrap().to_owned();
        self.accepted.push((id, kind, mode));
        response
    }

    fn deny_ws(&mut self, socket: &mut WebSocket<TcpStream>, frame: &Value) {
        let error = turn(socket, frame);
        assert_eq!(error["type"], "error", "{error}");
        assert_eq!(error["status"], 403, "{error}");
        self.denied(error);
    }

    fn deny_http(&mut self, port: u16, path: &str, frame: Value) {
        let (status, error) = request(port, "POST", path, Some(self.secret), Some(frame));
        assert_eq!(status, 403, "{error}");
        self.denied(error);
    }

    fn denied(&mut self, error: Value) {
        assert_eq!(error["error"]["code"], "reasoning_effort_not_allowed");
        self.denied
            .push(error["error"]["request_id"].as_str().unwrap().to_owned());
        assert!(
            self.reports.try_recv().is_err(),
            "rejected turn reached upstream"
        );
    }

    fn ledger(self, path: &Path, refused_size: &str) {
        assert!(
            self.reports.try_recv().is_err(),
            "unexpected upstream dispatch"
        );
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM attempts", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            i64::try_from(self.accepted.len()).unwrap() + 1
        );
        let mut accepted = db
            .prepare(
                "SELECT a.state, json_extract(a.admission_json, '$.mode'),
                        json_extract(a.admission_json, '$.reasoningEffort'),
                        json_extract(a.usage_json, '$.inputTokens'),
                        json_extract(a.usage_json, '$.outputTokens')
                 FROM attempts a JOIN bindings b ON b.attempt = a.id
                 WHERE b.raw_id = ?1 AND b.object_type = ?2",
            )
            .unwrap();
        for (id, kind, mode) in self.accepted {
            let stored = accepted
                .query_row([&id, kind], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                })
                .unwrap();
            assert_eq!(
                stored,
                ("settled".into(), mode.into(), "low".into(), 5, 3),
                "{id}"
            );
        }
        let refused = db
            .query_row(
                "SELECT state, json_extract(usage_json, '$.inputTokens'),
                               json_extract(usage_json, '$.outputTokens')
                 FROM attempts WHERE request_id = ?1",
                [refused_size],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(refused, ("settled".into(), 0, 0));
        for denied in self.denied {
            let (attempts, diagnoses) = db
                .query_row(
                    "SELECT (SELECT COUNT(*) FROM attempts WHERE request_id = ?1),
                            (SELECT COUNT(*) FROM request_diagnostics
                             WHERE request_id = ?1 AND reason = 'reasoning_effort_not_allowed')",
                    [&denied],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
                )
                .unwrap();
            assert_eq!((attempts, diagnoses), (0, 1), "{denied}");
        }
    }
}

#[test]
fn effort_policy_on_real_sockets() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    fs::create_dir(root.join("state")).unwrap();
    let master = "6f".repeat(32);
    private(&root.join("master"), &master);
    private(&root.join("admin"), ADMIN);
    private(
        &root.join("pool.json"),
        &json!({
            "models": [{"id": MODEL, "inputMicrosPerMillion": 1_000_000,
                "outputMicrosPerMillion": 1_000_000,
                "catalog": {"baseInstructions": "Synthetic fixture.",
                    "reasoningEfforts": ["low", "high"], "defaultReasoningEffort": "low"}}],
            "reservedMicros": 10, "upstreamTransport": "websocket",
        })
        .to_string(),
    );

    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let provider = listener.local_addr().unwrap().port();
    let path = root.join("state/core.sqlite");
    let database = Database::open_or_create(&path).unwrap();
    let cipher = AccountCredentialCipher::from_hex(&master, &[]).unwrap();
    seed_account(
        &database,
        &cipher,
        provider,
        "account-a",
        ("enabled", "ready", None),
        unix_time(),
    );
    drop(database);

    let (report, reports) = mpsc::channel();
    let (stop, stopping) = mpsc::channel::<()>();
    let upstream = thread::spawn(move || serve(listener, report, stopping));

    let (mut gateway, data, admin) = launch(root, provider);
    let limits = json!({"tokens": null, "active": 4});
    let (status, issued) = request(
        admin,
        "POST",
        "/api/keys",
        Some(ADMIN),
        Some(json!({
            "principal": "synthetic-effort-client", "models": [MODEL], "limits": limits,
            "reasoningEfforts": {(MODEL): ["low", "high"]}, "catalogRevision": 0,
        })),
    );
    assert_eq!(status, 201, "{issued}");
    let mut scenario = Scenario {
        secret: issued["secret"].as_str().unwrap(),
        reports,
        accepted: Vec::new(),
        denied: Vec::new(),
    };
    let mut socket = dial_ws(data, scenario.secret);
    let first = scenario.allow_ws(
        &mut socket,
        1,
        &create(input(&["high"]), "text"),
        "generation",
    );
    let next = scenario.allow_ws(&mut socket, 1, &continuation("text", &first), "generation");

    let key_id = issued["key"]["id"].as_str().unwrap();
    let (status, updated) = request(
        admin,
        "PUT",
        &format!("/api/keys/{key_id}"),
        Some(ADMIN),
        Some(json!({
            "revision": issued["key"]["revision"], "enabled": true, "models": [MODEL], "limits": limits,
            "reasoningEfforts": {(MODEL): ["low"]}, "catalogRevision": 0,
        })),
    );
    assert_eq!(status, 200, "{updated}");
    assert_eq!(updated["key"]["reasoningEfforts"][MODEL], json!(["low"]));
    scenario.deny_ws(&mut socket, &continuation("text", &next));

    scenario.allow_http(data, RESPONSES, &body(input(&["low", "low"])), Some(2));
    scenario.deny_http(data, RESPONSES, body(input(&["high", "low"])));
    let mut http_reference = body(input(&[]));
    http_reference["previous_response_id"] = json!(&next);
    scenario.deny_http(data, RESPONSES, http_reference);

    let compact = scenario.allow_http(data, COMPACT, &body(input(&["low"])), None);
    scenario.deny_http(data, RESPONSES, body(compact["output"].clone()));
    let mut stream = input(&[]);
    stream
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "compaction_trigger"}));
    let compact_id = scenario.allow_ws(&mut socket, 1, &create(stream, "text"), "compact");
    scenario.deny_ws(&mut socket, &continuation("text", &compact_id));

    let prior_socket = scenario.allow_ws(&mut socket, 1, &create(input(&[]), "text"), "generation");
    let refused = create(input(&[]), "size-refusal");
    let error = turn(&mut socket, &refused);
    assert_eq!(error["status"], 413, "{error}");
    assert_eq!(error["error"]["code"], "conversation_too_large");
    let refused_size = error["error"]["request_id"].as_str().unwrap().to_owned();
    scenario.seen(&refused, Some(1));

    // Establish a replacement upstream on another lane before referencing the old response.
    scenario.allow_ws(
        &mut socket,
        3,
        &create(input(&[]), "replacement"),
        "generation",
    );
    scenario.deny_ws(&mut socket, &continuation("text", &prior_socket));
    let recovered = scenario.allow_ws(&mut socket, 3, &create(input(&[]), "text"), "generation");
    let restart_id = scenario.allow_ws(
        &mut socket,
        3,
        &continuation("text", &recovered),
        "generation",
    );
    drop(socket);
    gateway.terminate();

    let (mut gateway, data, _) = launch(root, provider);
    let mut socket = dial_ws(data, scenario.secret);
    scenario.deny_ws(&mut socket, &continuation("text", &restart_id));
    drop(socket);
    let mut fresh = dial_ws(data, scenario.secret);
    scenario.allow_ws(&mut fresh, 4, &create(input(&[]), "text"), "generation");
    drop(fresh);
    gateway.terminate();

    let config_file = root.join("pool.json");
    let mut config: Value = serde_json::from_slice(&fs::read(&config_file).unwrap()).unwrap();
    config["upstreamTransport"] = json!("http");
    private(&config_file, &config.to_string());
    let (mut gateway, data, _) = launch(root, provider);
    scenario.allow_http(data, RESPONSES, &body(input(&["low", "low"])), None);
    scenario.deny_http(data, RESPONSES, body(input(&["high", "low"])));
    gateway.terminate();

    stop.send(()).unwrap();
    upstream.join().unwrap();
    scenario.ledger(&path, &refused_size);
}

fn serve(listener: TcpListener, report: mpsc::Sender<Dispatch>, stop: mpsc::Receiver<()>) {
    let sockets = Arc::new(AtomicUsize::new(0));
    let mut connections = Vec::new();
    while matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty)) {
        match listener.accept() {
            Ok((socket, _)) => {
                let sockets = sockets.clone();
                let report = report.clone();
                connections.push(thread::spawn(move || {
                    serve_connection(socket, &sockets, report)
                }));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("synthetic upstream: {error}"),
        }
    }
    for connection in connections {
        connection.join().unwrap();
    }
}

fn compaction() -> Value {
    json!([{"type": "compaction", "encrypted_content": "synthetic-compact-context"}])
}

fn usage() -> Value {
    json!({"input_tokens": 5, "output_tokens": 3, "input_tokens_details": {"cached_tokens": 0}})
}

// Tungstenite fixes the callback's rejection type.
#[allow(clippy::result_large_err)]
fn serve_connection(mut socket: TcpStream, sockets: &AtomicUsize, report: mpsc::Sender<Dispatch>) {
    socket.set_nonblocking(false).unwrap();
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let line = peek_request_line(&socket);
    if line.starts_with("GET /backend-api/codex/responses ") {
        let index = sockets.fetch_add(1, Ordering::Relaxed) + 1;
        let mut socket = accept_hdr(
            socket,
            |request: &server::Request, reply: server::Response| {
                assert_eq!(request.headers()["chatgpt-account-id"], "account-a");
                Ok(reply)
            },
        )
        .unwrap();
        let mut sequence = 0;
        while let Ok(Message::Text(frame)) = socket.read() {
            let request: Value = serde_json::from_str(frame.as_str()).unwrap();
            assert_eq!(request["type"], "response.create");
            let lane = request.get("stream_id").cloned();
            let compact = request["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["type"] == "compaction_trigger");
            report
                .send(Dispatch {
                    socket: Some(index),
                    body: request,
                })
                .unwrap();
            if lane.as_ref().is_some_and(|lane| lane == "size-refusal") {
                socket
                    .close(Some(CloseFrame {
                        code: CloseCode::Size,
                        reason: "synthetic".into(),
                    }))
                    .unwrap();
                return;
            }
            sequence += 1;
            let mut event = json!({
                "type": "response.completed", "response": {
                    "object": "response", "id": format!("resp_effort_{index}_{sequence}"),
                    "status": "completed", "model": MODEL,
                    "output": if compact { compaction() } else { json!([]) },
                    "usage": usage()
                }
            });
            if let Some(lane) = lane {
                event["stream_id"] = lane;
            }
            socket.send(Message::text(event.to_string())).unwrap();
        }
        return;
    }

    let mut reader = BufReader::new(&mut socket);
    let mut headers = String::new();
    while !headers.ends_with("\r\n\r\n") {
        assert_ne!(reader.read_line(&mut headers).unwrap(), 0);
    }
    if line.starts_with("GET /backend-api/wham/usage ") {
        write_response(&mut socket, "200 OK", "application/json", "{}");
        return;
    }
    let compact = line.starts_with(&format!("POST {COMPACT} "));
    assert!(
        compact || line.starts_with(&format!("POST {RESPONSES} ")),
        "{line}"
    );
    let length = headers
        .lines()
        .find_map(|header| {
            let (name, value) = header.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .unwrap();
    assert!(length <= 8192);
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    report
        .send(Dispatch {
            socket: None,
            body: serde_json::from_slice(&body).unwrap(),
        })
        .unwrap();
    if compact {
        let response = json!({
            "object": "response.compaction", "id": "compaction_effort_direct",
            "output": compaction(), "usage": usage()
        });
        write_response(
            &mut socket,
            "200 OK",
            "application/json",
            &response.to_string(),
        );
    } else {
        let created = json!({"type": "response.created", "response": {
            "id": "resp_effort_http", "status": "in_progress", "output": []
        }});
        let completed = json!({"type": "response.completed", "response": {
            "id": "resp_effort_http", "object": "response", "model": MODEL,
            "status": "completed", "output": [], "usage": usage()
        }});
        let sse = format!("data: {created}\n\ndata: {completed}\n\n");
        write_response(&mut socket, "200 OK", "text/event-stream", &sse);
    }
}
