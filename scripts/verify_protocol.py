#!/usr/bin/env python3
"""Real HTTP/SSE sockets against a credential-free local upstream and a temporary ledger."""
import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

TOKEN = "synthetic-client-token-for-local-tests"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        assert 0 <= length <= 524288
        payload = json.loads(self.rfile.read(length))
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        assert self.path in ("/v1/responses", "/v1/responses/compact")
        assert self.headers.get("Authorization") is None
        # Incoming client credentials and arbitrary headers must never reach the provider.
        assert self.headers.get("X-Synthetic-Secret") is None
        if payload.get("input") == "prefix-header":
            assert self.headers.get("x-codex-future-header") == "synthetic-value"
            assert self.headers.get("x-openai-actor-authorization") is None
        prompt = payload.get("input")
        if self.path == "/v1/responses/compact":
            response = {"id": f"cmp_{index}", "object": "response.compaction", "created_at": 1,
                        "output": [{"role": "user", "content": "synthetic retained message"},
                                   {"type": "compaction", "id": f"cmp_item_{index}", "encrypted_content": f"synthetic-compact-cipher-{index}"}],
                        "usage": {"input_tokens": 5, "output_tokens": 3, "input_tokens_details": {"cached_tokens": 0}}}
            if isinstance(payload.get("input"), list) and payload["input"]:
                response["output"].insert(1, payload["input"][0])
            fault = payload.get("instructions", "")
            if fault.startswith("synthetic-invalid-"):
                result = {"type": "function_call_output", "call_id": payload["input"][0]["call_id"], "output": "synthetic"}
                if fault == "synthetic-invalid-created":
                    response["created_at"] = {"file_id": "private-synthetic-file"}
                elif fault == "synthetic-invalid-part":
                    response["output"].insert(0, {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "synthetic", "refusal": {"file_id": "private-synthetic-file"}}]})
                else:
                    result[fault.removeprefix("synthetic-invalid-")] = {"file_id": "private-synthetic-file"}
                    response["output"].insert(0, result)
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        tool = prompt == "tool"
        item = ({"id": f"fc_{index}", "type": "function_call", "call_id": f"call_{index}",
                 "name": "local_tool", "arguments": "{}"} if tool else
                {"id": f"msg_{index}", "type": "message", "role": "assistant",
                 "content": [{"type": "output_text", "text": "synthetic output", "annotations": []}]})
        if prompt == "tool-namespace":
            item = {"id": f"fc_{index}", "type": "function_call", "call_id": f"call_{index}", "namespace": "synthetic_ns", "name": "local_tool", "arguments": "{}"}
        if prompt == "tool-custom":
            item = {"id": f"ctc_{index}", "type": "custom_tool_call", "call_id": f"call_{index}", "name": "local_custom", "input": "synthetic custom input"}
        if prompt == "refusal":
            item["content"] = [{"type": "refusal", "refusal": "synthetic refusal"}]
        if prompt == "bad-object":
            item["type"] = "unverified_private_object"
        response = {"id": f"resp_{index}", "object": "response", "status": "completed", "model": payload["model"],
                    "output": [item], "usage": {"input_tokens": 5, "output_tokens": 3,
                                                  "input_tokens_details": {"cached_tokens": 0}}}
        if payload.get("previous_response_id"):
            response["previous_response_id"] = payload["previous_response_id"]
        if prompt == "foreign-previous":
            response["previous_response_id"] = "private-synthetic-unbound-response"
        if prompt == "private-usage":
            response["usage"]["metadata"] = {"file_id": "private-synthetic-file"}
        if prompt == "provider-error":
            response["status"] = "failed"
            response["error"] = {"code": "synthetic", "message": "private-synthetic-provider-error"}
        if prompt == "reasoning":
            response["output"].insert(0, {"id": f"rs_{index}", "type": "reasoning", "summary": [], "encrypted_content": f"synthetic-reasoning-cipher-{index}"})
        try:
            if payload.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                created = {"type": "response.created", "response": {**response, "status": "in_progress", "output": [], "usage": None}}
                self.wfile.write(("data: " + json.dumps(created) + "\n\n").encode())
                self.wfile.flush()
                if prompt == "dribble":
                    for _ in range(80):
                        self.wfile.write(b'data: {"type":"response.output_text.delta","delta":"x"}\n\n')
                        self.wfile.flush()
                        time.sleep(0.05)
                    return
                if prompt == "private-part":
                    part = {"type": "response.content_part.done", "item_id": f"msg_{index}",
                            "part": {"type": "output_text", "text": "synthetic", "annotations":
                                     [{"type": "file_citation", "file_id": "private-synthetic-file"}]}}
                    self.wfile.write(("data: " + json.dumps(part) + "\n\n").encode())
                    self.wfile.flush()
                    return
                if prompt in ("bad-tail", "large-tail"):
                    terminal = ("data: " + json.dumps({"type": "response.completed", "response": response}) + "\n\n").encode()
                    tail = b'data: {bad json}\n\n' if prompt == "bad-tail" else b'data: ' + b'x' * 262_150 + b'\n\n'
                    self.wfile.write(terminal + tail)
                    self.wfile.flush()
                    return
                if prompt == "stall":
                    self.server.stalled.set()
                    self.connection.settimeout(6)
                    if self.connection.recv(1) == b"":
                        self.server.cancelled.set()
                    return
                if prompt == "abrupt":
                    return
                events = [{"type": "response.output_item.added", "item": item},
                          {"type": "response.completed", "response": response}]
                for event in events:
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            else:
                body = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except ConnectionResetError:
            if prompt == "stall":
                self.server.cancelled.set()
        except (BrokenPipeError, TimeoutError):
            pass
        finally:
            if payload.get("stream"):
                self.close_connection = True


def connect(port, method, path, payload=None, *, authorization=True, timeout=8, client_headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"Content-Type": "application/json", "X-Synthetic-Secret": "synthetic-header", **(client_headers or {})}
    if authorization:
        headers["Authorization"] = "Bearer " + TOKEN
    connection.request(method, path, body=json.dumps(payload) if payload is not None else None, headers=headers)
    response = connection.getresponse()
    body = response.read()
    status = response.status
    response.close()
    connection.close()
    return status, body


def start(binary, configuration, directory, *, admin_token_file=None, web_directory=None, admin_public_origin=None, account_master_key_file=None, account_pool_config=None, upstream_proxy=None):
    environment = {"PATH": os.defpath, "CODEXONE_DATA_PORT": "0", "CODEXONE_ADMIN_PORT": "0",
                               "CODEXONE_DATA_DIRECTORY": str(directory / "state")}
    if upstream_proxy is not None:
        environment["CODEXONE_UPSTREAM_HTTP_PROXY"] = upstream_proxy
    if account_pool_config is not None:
        environment["CODEXONE_ACCOUNT_POOL_CONFIG"] = str(account_pool_config)
    else:
        environment["CODEXONE_IDENTITY_CONFIG"] = str(configuration)
    if admin_token_file is not None:
        environment["CODEXONE_ADMIN_TOKEN_FILE"] = str(admin_token_file)
    if web_directory is not None:
        environment["CODEXONE_WEB_DIRECTORY"] = str(web_directory)
    if admin_public_origin is not None:
        environment["CODEXONE_ADMIN_PUBLIC_ORIGIN"] = admin_public_origin
    if account_master_key_file is not None:
        environment['CODEXONE_ACCOUNT_MASTER_KEY_FILE'] = str(account_master_key_file)
    process = subprocess.Popen([binary], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        ports = {}
        output = b""
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 20
            while len(ports) < 2 and time.monotonic() < deadline:
                assert process.poll() is None, "Configured gateway exited"
                for key, _ in selector.select(timeout=0.2):
                    output += os.read(key.fd, 8192)
                    assert len(output) < 131072
                    for name, port in re.findall(rb"LISTENING (data|admin) 127\.0\.0\.1:(\d+)", output):
                        ports[name.decode()] = int(port)
            assert len(ports) == 2, "Configured gateway did not listen"
        return process, ports
    except BaseException:
        stop(process)
        raise


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    process.stdout.close()


def latest(path, state):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        with sqlite3.connect(path) as db:
            row = db.execute("SELECT state,usage_json FROM attempts ORDER BY rowid DESC LIMIT 1").fetchone()
        if row and row[0] == state:
            return json.loads(row[1]) if row[1] else None
        time.sleep(0.02)
    raise AssertionError("Ledger did not reach expected state")


def web_smoke(port, state):
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["node", str(root / "web/scripts/live-overview.mjs"), str(port), state,
                    str(root / "artifacts/single-identity-ui")],
                   env={"PATH": os.environ.get("PATH", os.defpath)}, check=True, timeout=30)


def verify_model_profiles(binary):
    for supplied in (False, True, "upstream"):
        with tempfile.TemporaryDirectory(prefix="codexone-catalog-") as temporary:
            root = Path(temporary)
            model = {"id": "synthetic-text", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}
            if supplied is True:
                model["catalog"] = {"baseInstructions": "Explicit synthetic fixture guidance"}
            config = root / "identity.json"
            snapshot = root / "profiles.json"
            upstream = dict(slug="synthetic-text", base_instructions="Synthetic guidance",
                input_modalities=["text", "image"], prefer_websockets=True, priority=91,
                unknown={"nested": [True, None]}, shell_type="synthetic-shell")
            extra = {}
            if supplied == "upstream":
                snapshot.write_text(json.dumps(dict(version=1, source="synthetic", revision="v1",
                    capturedAtUnixSeconds=1, clientVersions=["0.163.0"],
                    models=[dict(id="synthetic-text", upstream=upstream)])))
                snapshot.chmod(0o600)
                extra["modelProfilesFile"] = str(snapshot)
            config.write_text(json.dumps({**extra, "principal": "p", "keyID": "k", "namespace": "synthetic", "identity": "i",
                "keySHA256": hashlib.sha256(TOKEN.encode()).hexdigest(), "reservedMicros": 0,
                "models": [model], "upstreamBaseURL": "http://127.0.0.1:9/v1"}))
            config.chmod(0o600)
            process, ports = start(binary, config, root)
            try:
                for prefix in ("/v1", "/backend-api/codex"):
                    assert connect(ports["data"], "GET", prefix + "/models?client_version=0.163.0", authorization=False)[0] == 401
                    for query in ("", "?client_version_extra=1", "?foo=client_version", "?client_version%00=1"):
                        status, body = connect(ports["data"], "GET", prefix + "/models" + query)
                        document = json.loads(body)
                        assert status == 200 and document["data"][0]["id"] == "synthetic-text"
                        assert ("models" in document) == bool(supplied)
                    for query in ("?client_version=0.163.0", "?client_version", "?client_version=1&client_version=2",
                                  "?%63lient_version=1", "?client_version=%ZZ"):
                        status, body = connect(ports["data"], "GET", prefix + "/models" + query)
                        if supplied:
                            assert status == 200 and json.loads(body)["models"][0]["base_instructions"]
                            if supplied == "upstream":
                                actual = json.loads(body)["models"][0]
                                assert actual.pop("codexone_profile")["source"] == "synthetic"
                                assert actual == {**upstream, "priority": 0, "input_modalities": ["text"], "prefer_websockets": False}
                        else:
                            assert status == 503 and b"model_catalog_unavailable" in body and b'"models"' not in body
                assert not sqlite3.connect(root / "state/core.sqlite").execute("SELECT 1 FROM attempts").fetchall()
            finally:
                stop(process)
    print("PASS: Codex catalog requires explicit complete profiles; parsed version queries select view, not authorization; OpenAI model list remains available")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web-smoke", action="store_true")
    args = parser.parse_args()
    verify_model_profiles(str(args.binary.resolve()))
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    upstream.daemon_threads = True
    upstream.guard = threading.Lock()
    upstream.calls = 0
    upstream.stalled = threading.Event()
    upstream.cancelled = threading.Event()
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="codexone-protocol-") as temporary:
            directory = Path(temporary)
            configuration = directory / "identity.json"
            configuration.write_text(json.dumps({"principal": "synthetic-principal", "keyID": "synthetic-key",
                "keySHA256": hashlib.sha256(TOKEN.encode()).hexdigest(), "namespace": "synthetic-provider",
                "identity": "synthetic-account", "reservedMicros": 10, "executionTimeoutSeconds": 2,
                "models": [{"id": "synthetic-text", "inputMicrosPerMillion": 1000000, "outputMicrosPerMillion": 1000000,
                            "catalog": {"baseInstructions": "Explicit synthetic fixture guidance"}}],
                "upstreamBaseURL": f"http://127.0.0.1:{upstream.server_port}/v1"}))
            configuration.chmod(0o600)
            process, ports = start(str(args.binary.resolve()), configuration, directory)
            try:
                port = ports["data"]
                db_path = directory / "state/core.sqlite"
                assert connect(port, "GET", "/health/ready")[0] == 200
                for prefix in ("/v1", "/backend-api/codex"):
                    status, body = connect(port, "GET", prefix + "/models")
                    assert status == 200 and json.loads(body)["data"][0]["id"] == "synthetic-text"
                    catalog = json.loads(body)["models"]
                    assert len(catalog) == 1 and catalog[0]["slug"] == "synthetic-text"
                    assert catalog[0]["input_modalities"] == ["text"] and not catalog[0]["supports_search_tool"]
                    assert connect(port, "GET", prefix + "/models", authorization=False)[0] == 401
                    status, body = connect(port, "POST", prefix + "/responses", {"model": "synthetic-text", "input": "text"})
                    assert status == 200 and json.loads(body)["status"] == "completed"
                    assert latest(db_path, "settled")["inputTokens"] == 5
                if args.web_smoke:
                    web_smoke(ports["admin"], "ready")
                count = upstream.calls
                for payload in ({"model": "other", "input": "text"},
                                {"model": "synthetic-text", "input": "text", "background": True},
                                {"model": "synthetic-text", "input": "text", "conversation": "synthetic-unowned"},
                                {"model": "synthetic-text", "input": "text", "previous_response_id": "unknown"}):
                    assert connect(port, "POST", "/v1/responses", payload)[0] in (400, 403)
                assert upstream.calls == count
                assert connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'prefix-header'}, client_headers={'x-codex-future-header': 'synthetic-value', 'x-openai-actor-authorization': 'synthetic-gate'})[0] == 200
                print("PASS: actual JSON/model routes, aliases, authentication, fail-before-dispatch and durable settlement")
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "tool", "tools": [{"type": "function", "name": "local_tool", "parameters": {"type": "object", "properties": {}}}]})
                response = json.loads(body)
                assert status == 200
                call = response["output"][0]["call_id"]
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "previous_response_id": response["id"],
                    "input": [{"type": "function_call_output", "call_id": call, "output": "synthetic result"}]})
                assert status == 200 and json.loads(body)["status"] == "completed"
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "text", "stream": True})
                assert status == 200 and b"response.completed" in body and b"[DONE]" in body
                assert latest(db_path, "settled")["estimatedMicros"] == 8
                print("PASS: function result ownership, continuation and SSE terminal usage")
                for prompt in ("bad-tail", "large-tail"):
                    status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": prompt, "stream": True})
                    assert status == 200 and b"response.completed" in body and b"[DONE]" in body
                    assert latest(db_path, "settled")["inputTokens"] == 5
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "private-part", "stream": True})
                # Provider parts are forwarded as-is; a stream without a terminal stays unknown.
                assert status == 200 and b"file_citation" in body and b"execution_indeterminate" in body
                assert latest(db_path, "unknown") is None
                began = time.monotonic()
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "dribble", "stream": True})
                assert status == 200 and b"execution_deadline_exceeded" in body and b"[DONE]" not in body
                assert 1 <= time.monotonic() - began < 4
                assert latest(db_path, "unknown") is None
                print("PASS: terminal evidence survives malformed/oversized coalesced tails; private parts blocked; progressing streams obey total deadline")
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "abrupt", "stream": True})
                assert status == 200 and b"execution_indeterminate" in body and b"[DONE]" not in body
                assert latest(db_path, "unknown") is None
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "bad-object"})
                assert status == 200 and json.loads(body)["output"][0]["type"] == "unverified_private_object"
                assert latest(db_path, "settled")["inputTokens"] == 5
                print("PASS: EOF remains unknown; unknown provider objects are forwarded with settled usage")
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "private-usage"})
                assert status == 200 and b"private-synthetic" not in body
                assert latest(db_path, "settled")["inputTokens"] == 5
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "provider-error"})
                failed = json.loads(body)
                assert status == 200 and failed["status"] == "failed" and failed["error"]["code"] == "synthetic"
                assert latest(db_path, "settled")["inputTokens"] == 5
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "foreign-previous"})
                assert status == 200 and latest(db_path, "settled")["inputTokens"] == 5
                print("PASS: usage metadata stays private; provider failures reach the client sanitized with settled counters")
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "refusal"})
                assert status == 200
                refused = json.loads(body)["output"]
                assert connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": refused + [{"role": "user", "content": "continue"}]})[0] == 200
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
                connection.request("POST", "/v1/responses", body=json.dumps({"model": "synthetic-text", "input": "stall", "stream": True}),
                                   headers={"Content-Type": "application/json", "Authorization": "Bearer " + TOKEN})
                response = connection.getresponse()
                assert response.status == 200
                assert response.readline().startswith(b"event:")
                assert upstream.stalled.wait(timeout=3)
                response.close()
                connection.close()
                assert upstream.cancelled.wait(timeout=5), "Upstream socket was not cancelled after downstream close"
                latest(db_path, "unknown")
                print("PASS: downstream close cancels silent upstream and finalizes unknown execution")
                with sqlite3.connect(db_path) as db:
                    db.execute("CREATE TRIGGER fail_binding BEFORE INSERT ON bindings BEGIN SELECT RAISE(ABORT,'synthetic fault'); END")
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "text"})
                assert status == 503 and b"resp_" not in body
                assert latest(db_path, "settled")["inputTokens"] == 5
                assert connect(port, "GET", "/health/ready")[0] == 503
                if args.web_smoke:
                    web_smoke(ports["admin"], "not-ready")
                count = upstream.calls
                assert connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "text"})[0] == 503
                assert upstream.calls == count
                print("PASS: binding write failure blocks exposure and later dispatch, preserves usage and lowers readiness")
                process.terminate()
                exit_code = process.wait(timeout=8)
                output = process.stdout.read()
                assert exit_code == 0, {"exit": exit_code, "cancelled": b"CancellationError" in output,
                                        "already_closed": b"alreadyClosed" in output, "closed_io": b"ioOnClosedChannel" in output}
                for marker in (TOKEN, "synthetic-header", "synthetic output", str(directory)):
                    assert marker.encode() not in output
                for bound_port in ports.values():
                    with socket.socket() as probe:
                        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                        probe.bind(("127.0.0.1", bound_port))
                print("PASS: configured protocol shutdown awaits sockets and avoids payload/credential/path logging")
            finally:
                stop(process)
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=3)


if __name__ == "__main__":
    main()
