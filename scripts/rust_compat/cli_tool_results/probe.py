#!/usr/bin/env python3
"""Probe Codex CLI 0.171.0 and independently exercise the gateway's opaque request fields."""

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from verify_client_protocol import GatewayLogs
from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, receive, send

VERSION = "codex-cli 0.171.0"
MODEL = "synthetic-text"
ACCOUNT = "synthetic-fixture-account"
UPSTREAM_TOKEN = "synthetic-upstream-token"
MARKER = "synthetic-private-connector-body-1ace7023"
FINISHED = "Synthetic connector probe completed."
VISIBLE = "synthetic lookup finished"
INCLUDE = ["reasoning.encrypted_content", "output.encrypted_content"]
BODY = {"content": [{"type": "text", "text": MARKER}], "structuredContent": {"marker": MARKER}}
CALL = {
    "name": "mcp__codex_apps__synthetic_lookup", "arguments": {},
    "tool_result": BODY,
}
METADATA = "internal_chat_message_metadata_passthrough"
CODE = f"""
const tool = ALL_TOOLS.find(tool => tool.name.endsWith('synthetic_lookup'));
if (!tool) throw Error('Synthetic connector unavailable');
await tools[tool.name]({{}});
text('{VISIBLE}');
"""


def response_events(document, index, item=None):
    warmup = document.get("generate") is False
    response = {
        "id": f"resp_synthetic_{index}", "object": "response", "model": MODEL,
        "status": "completed", "output": [item] if item else [],
        "usage": {"input_tokens": 0 if warmup else 5, "output_tokens": 0 if warmup else 3,
                  "total_tokens": 0 if warmup else 8, "input_tokens_details": {"cached_tokens": 0}},
    }
    yield {"type": "response.created", "response": {
        **response, "status": "in_progress", "output": [], "usage": None,
    }}
    if item:
        yield {"type": "response.output_item.done", "output_index": 0, "item": item}
    yield {"type": "response.completed", "response": response}


def final_item():
    return {"type": "message", "id": "msg_synthetic", "role": "assistant", "status": "completed",
            "phase": "final_answer", "content": [{"type": "output_text", "text": FINISHED,
                                                 "annotations": []}]}


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def json_reply(self, status, body):
        self.reply(status, json.dumps(body).encode())

    def capture(self, wire, document):
        with self.server.guard:
            self.server.records.append((wire, self.headers.get("Authorization"),
                                        self.headers.get("chatgpt-account-id"), document))
            return len(self.server.records)

    def events(self, document, index):
        if document.get("generate") is False:
            return response_events(document, index)
        if self.server.mode.startswith("cli") and index == 2:
            item = {"type": "custom_tool_call", "id": "ctc_synthetic", "call_id": "call_synthetic",
                    "name": "exec", "input": CODE}
            return response_events(document, index, item)
        return response_events(document, index, final_item())

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        assert 0 < length <= 524288
        document = json.loads(self.rfile.read(length))
        if self.path.rstrip("/").endswith("/ps/mcp"):
            self.apps_rpc(document)
            return
        assert self.path == "/v1/responses"
        index = self.capture("http", document)
        events = self.events(document, index)
        if document.get("stream"):
            self.reply(200, b"".join(b"data: " + json.dumps(event).encode() + b"\n\n" for event in events),
                       "text/event-stream")
        else:
            self.json_reply(200, list(events)[-1]["response"])

    def apps_rpc(self, rpc):
        method = rpc["method"]
        if "id" not in rpc:
            self.reply(202)
            return
        if method == "initialize":
            result = {"protocolVersion": rpc["params"]["protocolVersion"],
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": "Synthetic Apps", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "synthetic_lookup", "description": "Synthetic lookup",
                                 "annotations": {"readOnlyHint": True},
                                 "inputSchema": {"type": "object"},
                                 "_meta": {"connector_id": "synthetic_connector",
                                           "connector_name": "Synthetic Connector"}}]}
        elif method == "tools/call":
            assert rpc["params"]["name"] == "synthetic_lookup"
            with self.server.guard:
                self.server.apps_calls += 1
            result = BODY
        else:
            self.json_reply(200, {"jsonrpc": "2.0", "id": rpc["id"],
                                  "error": {"code": -32601, "message": "Unsupported fixture method"}})
            return
        self.json_reply(200, {"jsonrpc": "2.0", "id": rpc["id"], "result": result})

    def do_GET(self):
        if self.path != "/v1/responses":
            if "/connectors/directory/list" in self.path:
                self.json_reply(200, {"apps": [], "nextToken": None})
            else:
                self.reply(404)
            return
        assert self.headers.get("Upgrade", "").lower() == "websocket"
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True
        self.connection.settimeout(10)
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                if opcode == 9:
                    send(self.connection, data, opcode=10)
                    continue
                assert opcode == 1
                document = json.loads(data)
                assert document["type"] == "response.create"
                index = self.capture("ws", document)
                if (self.server.mode, index) in (("cli-fallback", 3), ("gateway-fallback", 1)):
                    send(self.connection, struct.pack("!H", 1009), opcode=8)
                    return
                for event in self.events(document, index):
                    send(self.connection, event)
        except (EOFError, ConnectionError, TimeoutError):
            return


class Fixture(ThreadingHTTPServer):
    # Propagate only the class of an error. HTTP request values stay in the probe.
    def handle_error(self, *_args):
        with self.guard:
            self.errors.append(sys.exc_info()[0].__name__)


@contextmanager
def provider(mode):
    with Fixture(("127.0.0.1", 0), Provider) as server:
        server.guard = threading.Lock()
        server.records = []
        server.errors = []
        server.apps_calls = 0
        server.mode = mode
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            yield server
            assert not server.errors, server.errors
        finally:
            server.shutdown()
            worker.join()


def origin(server):
    return f"http://127.0.0.1:{server.server_port}"


def write_private(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
        file.write(value)


def assert_marker_absent(log):
    marker = MARKER.encode()
    assert marker not in log and marker.hex().encode() not in log.lower(), "Private marker in diagnostic log"


def cli_probe(codex, root, mode):
    root.mkdir()
    home = root / "codex"
    home.mkdir()
    work = root / "work"
    work.mkdir()
    claim = base64.urlsafe_b64encode(json.dumps({
        "email": "synthetic@example.invalid",
        "https://api.openai.com/auth": {"chatgpt_account_id": ACCOUNT, "chatgpt_plan_type": "pro"},
    }).encode()).decode().rstrip("=")
    token = f"e30.{claim}.synthetic"
    write_private(home / "auth.json", json.dumps({
        "auth_mode": "chatgpt", "tokens": {
            "id_token": token, "access_token": token, "refresh_token": "synthetic", "account_id": ACCOUNT,
        }, "last_refresh": datetime.now(timezone.utc).isoformat(),
    }))
    with provider(mode) as server:
        write_private(home / "config.toml", f"""
model_provider = "fixture"
model = "{MODEL}"
chatgpt_base_url = "{origin(server)}/backend-api"
cli_auth_credentials_store = "file"
web_search = "disabled"
[features]
apps = true
code_mode = true
code_mode_only = true
executed_tool_call_metadata = true
output_token_replay = true
enable_request_compression = false
[model_providers.fixture]
name = "OpenAI"
base_url = "{origin(server)}/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = true
stream_max_retries = 0
request_max_retries = 0
[analytics]
enabled = false
[feedback]
enabled = false
""")
        env = {"PATH": os.defpath, "HOME": str(root), "CODEX_HOME": str(home),
               "OTEL_SDK_DISABLED": "true", "RUST_LOG": "tungstenite::protocol=trace,codex_api=trace"}
        result = subprocess.run([codex, "exec", "--strict-config", "--skip-git-repo-check",
                                 "--json", "--sandbox", "read-only", "Run the synthetic lookup once and finish."],
                                cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=35)
        records = list(server.records)
        wires = [wire for wire, *_ in records]
        assert result.returncode == 0 and FINISHED.encode() in result.stdout, (
            mode, result.returncode, wires, server.apps_calls, server.errors,
        )
        assert server.apps_calls == 1, "Expected one actual Hosted Apps RPC"
        output_events = [json.loads(line) for line in result.stdout.splitlines()]
        app_results = [event["item"] for event in output_events if event["type"] == "item.completed"
                       and event["item"]["type"] == "mcp_tool_call"]
        assert len(app_results) == 1 and app_results[0]["status"] == "completed"
        assert MARKER in json.dumps(app_results[0]["result"]), "CLI did not receive the private marker"
        assert wires == (["ws", "ws", "ws", "http"] if mode == "cli-fallback" else ["ws", "ws", "ws"]), wires
        assert records[0][3].get("generate") is False
        assert all(account == ACCOUNT and auth == f"Bearer {token}" for _, auth, account, _ in records)
        for _, _, _, document in records:
            assert document["include"] == INCLUDE
            encoded = json.dumps(document)
            assert all(value not in encoded for value in (MARKER, '"tool_result":', '"tool_result_call_id":'))
        assert records[2][3].get("previous_response_id") == "resp_synthetic_2"
        assert all(any(item.get("call_id") == "call_synthetic"
                       and item["type"] == "custom_tool_call_output"
                       and VISIBLE in json.dumps(item["output"]) for item in document["input"])
                   for _, _, _, document in records[2:]), "Ordinary tool output was dropped"
        if mode == "cli-fallback":
            assert records[-1][3].get("previous_response_id") is None
        assert b"TRACE tungstenite::protocol" in result.stderr, "WebSocket trace was unavailable"
        assert_marker_absent(result.stderr)
        return {"wire": wires, "warmup": True, "appsCalls": server.apps_calls,
                "sameAccount": True, "include": INCLUDE, "privateBodyOnWire": False,
                "ordinaryToolOutputOnWire": True, "privateMarkerInStderr": False,
                "privateBodyInExplicitToolEvent": True}


def synthetic_request():
    return {
        "model": MODEL, "include": INCLUDE, "stream": False,
        "input": [{"type": "custom_tool_call_output", "id": "local_synthetic_output",
                   "call_id": "call_synthetic", "output": "Synthetic visible result.",
                   METADATA: {"executed_tool_calls": [CALL]}}],
    }


def gateway_probe(binary, root, mode):
    root.mkdir()
    upstream_token_file = root / "upstream-token"
    write_private(upstream_token_file, UPSTREAM_TOKEN + "\n")
    with provider(mode) as server:
        config = root / "identity.json"
        write_private(config, json.dumps({
            "principal": "synthetic-principal", "keyID": "synthetic-key",
            "keySHA256": hashlib.sha256(TOKEN.encode()).hexdigest(), "namespace": "synthetic-provider",
            "identity": ACCOUNT, "reservedMicros": 10, "upstreamTransport": "websocket",
            "upstreamBaseURL": origin(server) + "/v1", "upstreamTokenFile": str(upstream_token_file),
            "models": [{"id": MODEL, "inputMicrosPerMillion": 1000000, "outputMicrosPerMillion": 1000000}],
        }))
        process, ports = start(binary, config, root)
        capture = GatewayLogs(process)
        try:
            request = synthetic_request()
            if mode == "gateway-fallback":
                status, response = connect(ports["data"], "POST", "/v1/responses", request)
                assert status == 200 and json.loads(response)["status"] == "completed", status
                expected = ["ws", "http"]
            else:
                with dial(ports["data"]) as sock:
                    # Match a real initial CLI prewarm: no tool result exists yet.
                    warmup = {**request, "type": "response.create", "generate": False, "input": []}
                    send(sock, warmup, masked=True)
                    assert ws_done(sock)["output"] == []
                    send(sock, {**request, "type": "response.create"}, masked=True)
                    assert ws_done(sock)["status"] == "completed"
                expected = ["ws", "ws"]
        finally:
            logs = process.gateway_startup_output + stop(process, drain_stdout=capture.read)
        assert process.returncode == 0, "Gateway shutdown failed"
        assert_marker_absent(logs)
        wires = [wire for wire, *_ in server.records]
        assert wires == expected, wires
        for _, auth, _, document in server.records:
            assert auth == f"Bearer {UPSTREAM_TOKEN}"
            assert document["include"] == INCLUDE
            if document.get("generate") is False:
                assert MARKER not in json.dumps(document)
            else:
                item, = document["input"]
                assert item[METADATA]["executed_tool_calls"] == [CALL]
                assert "id" not in item
        if mode == "gateway-fallback":
            assert b"path=http_1009 " in logs, "Expected safe 1009 bridge fallback diagnostic"
        with sqlite3.connect(f"file:{root / 'state/core.sqlite'}?mode=ro", uri=True) as db:
            attempts = db.execute("SELECT state, identity FROM attempts ORDER BY rowid").fetchall()
        assert attempts == [("settled", ACCOUNT)] * (1 if mode == "gateway-fallback" else 2), attempts
        return {"wire": wires, "include": INCLUDE, "privateBodyOnGeneration": True,
                "privateMarkerInGatewayLogs": False, "accountVerified": True, "settled": len(attempts)}


def ws_done(sock):
    for _ in range(4):
        opcode, data = receive(sock)
        assert opcode == 1
        event = json.loads(data)
        if event.get("type") == "response.completed":
            return event["response"]
    raise AssertionError("Missing synthetic terminal event")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Rust CodexOne gateway")
    parser.add_argument("--codex", default="codex")
    args = parser.parse_args()
    codex = shutil.which(args.codex)
    assert codex, "Codex CLI executable was not found"
    codex = str(Path(codex).absolute())
    assert subprocess.check_output([codex, "--version"], timeout=10, text=True).strip() == VERSION, VERSION
    with tempfile.TemporaryDirectory(prefix="codexone-cli-tool-results-") as temp:
        root = Path(temp)
        print(json.dumps({
            "version": VERSION,
            "cli": {mode: cli_probe(codex, root / mode, mode) for mode in ("cli-normal", "cli-fallback")},
            "handWritten": {mode: gateway_probe(str(args.binary.resolve()), root / mode, mode)
                            for mode in ("gateway-native", "gateway-fallback")},
        }, indent=2))


if __name__ == "__main__":
    main()
