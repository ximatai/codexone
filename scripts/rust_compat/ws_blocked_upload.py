#!/usr/bin/env python3
"""Verify blocked WS uploads with the Rust gateway, loopback TCP and a temporary v19 database.

Run after cargo build --locked --manifest-path rust/gateway/Cargo.toml:
    python3 scripts/rust_compat/ws_blocked_upload.py --binary rust/gateway/target/debug/codexone
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import socket
import sqlite3
import struct
import tempfile
import threading
import time

from compare import ProbeError, fixture, health, require, running_gateway
from verify_protocol import TOKEN
from verify_websocket import dial, exact, receive, send

MIB = 1024 * 1024
LARGE_INPUT = "x" * (11 * MIB)
PATH = "/v1/responses"
TOTAL = 7
FIRST_RESPONSE = 1
IO_TIMEOUT = TOTAL + 4
PING = b"synthetic-blocked-upload"
MODES = ("native", "bridge", "bridge-sse")
CASES = ("size", "started_size", "eof", "silent", "resume")
FOLLOWUP_ID = "resp_synthetic_followup"
RESPONSE = {
    "id": "resp_synthetic_upload", "object": "response", "model": "synthetic-text",
    "status": "completed", "output": [],
    "usage": {"input_tokens": 5, "output_tokens": 3, "total_tokens": 8,
              "input_tokens_details": {"cached_tokens": 0}},
}


class Scenario:
    def __init__(self, name):
        self.name = name
        self.header = threading.Event()
        self.release = threading.Event()
        self.drain = threading.Event()
        self.finished = threading.Event()
        self.body_bytes = None
        self.frame_length = None
        self.pong = False
        self.error = None
        self.pong_at = None

    def blocked_upload(self, peer):
        # Read the complete masked client frame header and leave every payload byte unread.
        prefix = exact(peer, 2)
        require(prefix == b"\x81\xff", "expected one large masked text frame")
        self.frame_length = struct.unpack("!Q", exact(peer, 8))[0]
        require(len(LARGE_INPUT) < self.frame_length < 12 * MIB, "create missed the WS routing window")
        exact(peer, 4)
        send(peer, PING, opcode=9)
        self.header.set()
        require(self.release.wait(IO_TIMEOUT), "scenario did not release the provider")
        if self.name == "size":
            send(peer, {"type": "rate_limits.updated", "rate_limits": []})
        if self.name == "started_size":
            send(peer, {"type": "response.created", "response": {
                "id": RESPONSE["id"], "status": "in_progress", "output": [],
            }})
        if self.name in ("size", "started_size"):
            send(peer, struct.pack("!H", 1009), opcode=8)
        if self.name in ("size", "started_size", "eof"):
            # EOF follows any WS Close on the wire. Keep the receive half open so
            # the fixture can measure how many bytes actually entered TCP.
            peer.shutdown(socket.SHUT_WR)
        if self.name != "resume":
            require(self.drain.wait(IO_TIMEOUT), "gateway did not return while upstream was stalled")
        self.body_bytes = self.drain_frame(peer)
        if self.name == "resume":
            require(self.body_bytes == self.frame_length, "resumed provider did not receive the full create")
            opcode, payload = receive(peer, masked=True)
            require((opcode, payload) == (10, PING), "provider did not receive the queued Pong")
            self.pong = True
            self.pong_at = time.monotonic()
            # Remain silent after Pong so the gateway's first-response timer can fire.
            require(self.drain.wait(IO_TIMEOUT), "gateway did not return after resumed upload")
        else:
            require(self.body_bytes < self.frame_length, "the provider did not backpressure this upload")
            require(self.body_bytes > 0, "the provider saw no upload bytes after the header")

    def drain_frame(self, peer):
        remaining = self.frame_length
        while remaining:
            try:
                part = peer.recv(min(remaining, 64 * 1024))
            except ConnectionResetError:
                break
            if not part:
                break
            remaining -= len(part)
        return self.frame_length - remaining


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    rbufsize = 0  # HTTP handshake parsing must not read websocket payload into a user-space buffer.

    def log_message(self, *_):
        pass

    def record(self, transport):
        with self.server.guard:
            self.server.trace.append(transport)
            return len(self.server.trace)

    def do_GET(self):
        self.close_connection = True
        number = self.record("ws")
        scenario = self.server.scenario
        try:
            require(self.path == PATH, "unexpected provider upgrade path")
            self.connection.settimeout(IO_TIMEOUT)
            if number == 1:
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024)
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode(),
            ).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            if number == 1:
                scenario.blocked_upload(self.connection)
            else:
                opcode, payload = receive(self.connection, masked=True)
                require(opcode == 1 and json.loads(payload)["input"] == "synthetic follow-up",
                        "unexpected create on subsequent provider connection")
                send(self.connection, {"type": "response.completed",
                                       "response": {**RESPONSE, "id": FOLLOWUP_ID}})
        except (OSError, ValueError, ProbeError, EOFError, AssertionError) as error:
            scenario.error = error
        finally:
            if number == 1:
                scenario.finished.set()

    def do_POST(self):
        self.close_connection = True
        self.record("http")
        try:
            require(self.path == PATH, "unexpected provider HTTP path")
            self.connection.settimeout(IO_TIMEOUT)
            length = int(self.headers.get("Content-Length", 0))
            require(len(LARGE_INPUT) < length < 12 * MIB, "fallback lost the original request size")
            body = json.loads(exact(self.connection, length))
            require(body.get("input") == LARGE_INPUT and body.get("model") == RESPONSE["model"],
                    "fallback changed the request body")
            require(body.get("stream", False) is self.server.streaming, "fallback changed response format")
            if self.server.streaming:
                completion = json.dumps({"type": "response.completed", "response": RESPONSE})
                payload = f"data: {completion}\n\ndata: [DONE]\n\n".encode()
                content_type = "text/event-stream"
            else:
                payload = json.dumps(RESPONSE).encode()
                content_type = "application/json"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (OSError, ValueError, ProbeError, EOFError) as error:
            self.server.scenario.error = error


def request(port, body, native=None):
    if native is not None:
        send(native, {"type": "response.create", **body}, masked=True, maximum_bytes=12 * MIB)
        events = []
        while True:
            opcode, payload = receive(native)
            require(opcode == 1, "native connection closed before the result")
            event = json.loads(payload)
            events.append(event)
            if event["type"] in ("response.completed", "error"):
                return event.get("status", 200), event, events
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=IO_TIMEOUT)) as connection:
        connection.request("POST", PATH, json.dumps(body),
                           {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
        reply = connection.getresponse()
        raw = reply.read(64 * 1024)
        if reply.headers.get_content_type() == "text/event-stream":
            events = [json.loads(line[6:]) for line in raw.splitlines()
                      if line.startswith(b"data: ") and line != b"data: [DONE]"]
            require(events, "SSE bridge returned no events")
            return reply.status, events[-1], events
        return reply.status, json.loads(raw), []


def check_shared_lease(port, *, available):
    # Compact uses the same in-memory budget, including when HTTP staging is
    # enabled. It cannot report invalid_json until it acquires the full budget
    # and reads the body. 100 Continue alone also occurs while waiting.
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=IO_TIMEOUT)) as connection:
        connection.putrequest("POST", f"{PATH}/compact")
        connection.putheader("Authorization", f"Bearer {TOKEN}")
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", str(64 * MIB))
        connection.putheader("Connection", "close")
        connection.endheaders()
        if available:
            chunk = b"x" * MIB
            for _ in range(64):
                connection.send(chunk)
        reply = connection.getresponse()
        expected = (400, "invalid_json") if available else (503, "capacity_exhausted")
        actual = reply.status, json.loads(reply.read(64 * 1024))["error"]["code"]
        require(actual == expected, f"full shared body lease: expected {expected}, got {actual}")
        # Both requests stop before execution admission.


def ledger_rows(database):
    deadline = time.monotonic() + 3
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        require(db.execute("PRAGMA user_version").fetchone() == (19,), "expected a synthetic v19 database")
        while True:
            rows = db.execute("SELECT state, outcome_json, usage_json FROM attempts ORDER BY rowid").fetchall()
            if len(rows) == 2 and all(state != "intent" and outcome for state, outcome, _ in rows):
                break
            require(time.monotonic() < deadline, "expected exactly two finalized executions in the live ledger")
            time.sleep(0.02)
        bindings = db.execute("SELECT raw_id FROM bindings WHERE attempt = "
                              "(SELECT id FROM attempts ORDER BY rowid LIMIT 1)").fetchall()
    return rows, bindings


def check_ledger(database, scenario, mode):
    rows, bindings = ledger_rows(database)
    native = mode == "native"
    state, outcome, usage = rows[0]
    outcome = json.loads(outcome)
    usage = json.loads(usage) if usage is not None else {}
    if scenario.name == "size":
        require(state == "settled", "early 1009 left the execution unknown")
        require(outcome.get("failure") == ("invalid_request" if native else None), "wrong 1009 outcome")
    else:
        require(state == "unknown", f"missing unknown execution responsibility (state={state})")
        failure = "deadline_exceeded" if scenario.name in ("silent", "resume") else "indeterminate"
        require(outcome.get("failure") == failure, f"wrong execution failure: {outcome.get('failure')}")
        require(usage.get("completeness") != "complete", "an uncertain upload became complete usage")
    if scenario.name == "started_size":
        require(outcome.get("firstEventMilliseconds") is not None, "lost trusted response.created evidence")
        require(mode == "bridge" or (RESPONSE["id"],) in bindings, "lost trusted response binding")
    elif scenario.name != "size":
        require(outcome.get("firstEventMilliseconds") is None and not bindings,
                "Ping, EOF or deadline produced trusted execution evidence")
    elif native:
        require(not bindings, "pre-lifecycle metadata produced a response binding")
    if state == "settled":
        expected = (0, 0) if native else (5, 3)
        require(usage.get("completeness") == "complete"
                and (usage.get("inputTokens"), usage.get("outputTokens")) == expected,
                "size refusal or fallback has incorrect usage")
    followup_state, followup_outcome, followup_usage = rows[1]
    require(followup_state == "settled" and json.loads(followup_outcome)["kind"] == "succeeded"
            and json.loads(followup_usage).get("completeness") == "complete",
            f"follow-up execution did not settle with complete usage (state={followup_state})")
    return state, outcome.get("failure")


def verify(binary, root, mode, name):
    scenario = Scenario(name)
    with fixture(root, handler=Provider) as (server, database, environment):
        server.scenario = scenario
        server.trace = []
        server.streaming = mode == "bridge-sse"
        config = Path(environment["CODEXONE_IDENTITY_CONFIG"])
        settings = json.loads(config.read_text())
        settings.update(upstreamTransport="websocket", executionTimeoutSeconds=TOTAL,
                        firstResponseTimeoutSeconds=FIRST_RESPONSE)
        config.write_text(json.dumps(settings))
        with running_gateway(binary, root, environment) as ports, ExitStack() as stack:
            health(ports)
            port = ports["data"]
            native = mode == "native"
            peer = stack.enter_context(dial(port, timeout=IO_TIMEOUT)) if native else None
            workers = stack.enter_context(ThreadPoolExecutor(max_workers=1))
            try:
                result = workers.submit(request, port, {
                    "input": LARGE_INPUT, "model": RESPONSE["model"], "stream": server.streaming,
                }, peer)
                require(scenario.header.wait(3), f"provider did not see frame header ({scenario.error})")
                header_at = time.monotonic()
                if name == "silent":
                    check_shared_lease(port, available=False)
                if name == "resume":
                    # Stay blocked beyond the configured first-response timeout.
                    require(not scenario.finished.wait(FIRST_RESPONSE + 0.30) and not result.done(),
                            "request finished before the provider resumed reading")
                scenario.release.set()
                status, body, events = result.result(timeout=IO_TIMEOUT)
                returned = time.monotonic()
            finally:
                scenario.release.set()
                scenario.drain.set()
            require(scenario.finished.wait(IO_TIMEOUT), "provider socket did not retire")
            require(scenario.error is None, f"provider failed: {scenario.error}")
            validate_result(scenario, mode, status, body, events, header_at, returned)
            expected = ["ws", "http"] if name == "size" and not native else ["ws"]
            require(server.trace == expected, f"unexpected provider calls: {server.trace}")
            check_shared_lease(port, available=True)
            # An early 1009 leaves the native client socket open for a new turn.
            if native and name != "size":
                peer.close()
                peer = stack.enter_context(dial(port, timeout=IO_TIMEOUT))
            repeat_status, repeat, _ = request(port, {
                "input": "synthetic follow-up", "model": RESPONSE["model"], "stream": server.streaming,
            }, peer)
            require(repeat_status == 200 and repeat.get("response", repeat).get("id") == FOLLOWUP_ID,
                    "independent turn could not acquire a fresh execution lease")
            require(server.trace == expected + ["ws"], f"unexpected follow-up traffic: {server.trace}")
            require(scenario.error is None, f"provider failed: {scenario.error}")
            state, failure = check_ledger(database, scenario, mode)
    return {
        "mode": mode, "case": name, "status": status, "state": state, "failure": failure,
        "upstreamCalls": expected, "secondsFromFrameHeader": round(returned - header_at, 3),
        "frameBytes": scenario.frame_length, "receivedBytes": scenario.body_bytes,
        **({"pongAfterResume": True} if scenario.pong else {}),
    }


def validate_result(scenario, mode, status, body, events, header_at, returned):
    name = scenario.name
    if name == "size" and mode != "native":
        require(status == 200 and body.get("response", body).get("id") == RESPONSE["id"],
                "bridge did not use its one HTTP fallback")
        if mode == "bridge-sse":
            require([event["type"] for event in events] == ["response.completed"],
                    "fallback leaked connection metadata")
    else:
        expected = {
            "size": (413, "conversation_too_large"),
            "started_size": (502, "execution_indeterminate"),
            "eof": (502, "execution_indeterminate"),
            "silent": (504, "execution_deadline_exceeded"),
            "resume": (504, "execution_first_response_timeout"),
        }[name]
        if mode == "bridge-sse" and name == "started_size":
            require(status == 200, "SSE status changed after the first event")
            expected = 200, expected[1]
        actual = status, body.get("error", {}).get("code")
        require(actual == expected, f"expected {expected}, got {actual}")
    if name == "started_size" and mode != "bridge":
        require([event["type"] for event in events] == ["response.created", "error"],
                "response.created did not reach the client before the error")
    if name == "size" and mode == "native":
        require([event["type"] for event in events] == ["error"], "early 1009 leaked buffered metadata")
    if name == "silent":
        require(TOTAL - 1 <= returned - header_at < TOTAL + 2, "upload did not wait for the total deadline")
    elif name == "resume":
        require(scenario.pong and 0.45 <= returned - scenario.pong_at < FIRST_RESPONSE + 1.5,
                "Pong did not flush or first response timeout did not begin at upload completion")
        require(returned - header_at < TOTAL - 0.5, "resumed upload hit the total deadline")
    else:
        require(returned - header_at < 4, "provider reply waited for the blocked write's deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--mode", choices=MODES, action="append")
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    failures = []
    with tempfile.TemporaryDirectory(prefix="codexone-ws-blocked-") as temporary:
        for mode in args.mode or MODES:
            for name in args.case or CASES:
                try:
                    print(json.dumps(verify(binary, Path(temporary) / f"{mode}-{name}", mode, name)), flush=True)
                except (OSError, EOFError, ValueError, ProbeError, AssertionError) as error:
                    failures.append(f"{mode}/{name}: {error}")
    if failures:
        parser.exit(1, "\n".join(failures) + "\n")


if __name__ == "__main__":
    main()
