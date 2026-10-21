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
        assert self.path == "/v1/responses"
        assert self.headers.get("Authorization") is None
        # Incoming client credentials and arbitrary headers must never reach the provider.
        assert self.headers.get("X-Synthetic-Secret") is None
        prompt = payload.get("input")
        tool = prompt == "tool"
        item = ({"id": f"fc_{index}", "type": "function_call", "call_id": f"call_{index}",
                 "name": "local_tool", "arguments": "{}"} if tool else
                {"id": f"msg_{index}", "type": "message", "role": "assistant",
                 "content": [{"type": "output_text", "text": "synthetic output", "annotations": []}]})
        if prompt == "bad-object":
            item["type"] = "unverified_private_object"
        response = {"id": f"resp_{index}", "object": "response", "status": "completed", "model": payload["model"],
                    "output": [item], "usage": {"input_tokens": 5, "output_tokens": 3,
                                                  "input_tokens_details": {"cached_tokens": 0}}}
        try:
            if payload.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                created = {"type": "response.created", "response": {**response, "status": "in_progress", "output": [], "usage": None}}
                self.wfile.write(("data: " + json.dumps(created) + "\n\n").encode())
                self.wfile.flush()
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


def connect(port, method, path, payload=None, *, authorization=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
    headers = {"Content-Type": "application/json", "X-Synthetic-Secret": "synthetic-header"}
    if authorization:
        headers["Authorization"] = "Bearer " + TOKEN
    connection.request(method, path, body=json.dumps(payload) if payload is not None else None, headers=headers)
    response = connection.getresponse()
    body = response.read()
    status = response.status
    response.close()
    connection.close()
    return status, body


def start(binary, configuration, directory):
    process = subprocess.Popen([binary], env={"PATH": os.defpath, "CODEXONE_DATA_PORT": "0", "CODEXONE_ADMIN_PORT": "0",
                               "CODEXONE_DATA_DIRECTORY": str(directory / "state"), "CODEXONE_IDENTITY_CONFIG": str(configuration)},
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--web-smoke", action="store_true")
    args = parser.parse_args()
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
                "identity": "synthetic-account", "reservedMicros": 10,
                "models": [{"id": "synthetic-text", "inputMicrosPerMillion": 1000000, "outputMicrosPerMillion": 1000000}],
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
                    assert connect(port, "GET", prefix + "/models", authorization=False)[0] == 401
                    status, body = connect(port, "POST", prefix + "/responses", {"model": "synthetic-text", "input": "text"})
                    assert status == 200 and json.loads(body)["status"] == "completed"
                    assert latest(db_path, "settled")["inputTokens"] == 5
                if args.web_smoke:
                    web_smoke(ports["admin"], "ready")
                count = upstream.calls
                for payload in ({"model": "other", "input": "text"},
                                {"model": "synthetic-text", "input": "text", "background": True},
                                {"model": "synthetic-text", "input": "text", "tools": [{"type": "web_search"}]},
                                {"model": "synthetic-text", "input": "text", "previous_response_id": "unknown"}):
                    assert connect(port, "POST", "/v1/responses", payload)[0] in (400, 403)
                assert upstream.calls == count
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
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "abrupt", "stream": True})
                assert status == 200 and b"execution_indeterminate" in body and b"[DONE]" not in body
                assert latest(db_path, "unknown") is None
                status, body = connect(port, "POST", "/v1/responses", {"model": "synthetic-text", "input": "bad-object"})
                assert status == 502 and b"resp_" not in body
                assert latest(db_path, "settled")["inputTokens"] == 5
                print("PASS: EOF remains unknown; known usage survives rejected provider objects without ID exposure")
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
