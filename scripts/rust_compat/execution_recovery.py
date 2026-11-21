#!/usr/bin/env python3
"""Check execution recovery across SIGKILL and a subsequent graceful restart."""
import argparse
from contextlib import closing
import http.client
import json
from pathlib import Path
import re
import sqlite3
import stat
import tempfile
import threading
import time

from compare import (
    TOKEN, ProbeError, Upstream, fixture, generate, health, request, require, running_gateway,
)


PHASES = ("before_intent", "after_intent", "after_binding", "after_settlement")
OWNER = ("synthetic-principal", "synthetic-key", "synthetic-account")
SUFFIXES = ("", ".lock", "-wal", "-shm")
USAGE = {"inputTokens": 5, "outputTokens": 3, "estimatedMicros": 8, "completeness": "complete"}


class PausedUpstream(Upstream):
    def do_POST(self):
        if not self.server.pause or self.server.release.is_set():
            super().do_POST()
            return

        # Consume the request and record dispatch before producing any response bytes.
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.server.guard:
            self.server.calls += 1
        require(self.path == "/v1/responses" and payload["model"] == "synthetic-text",
                "unexpected interrupted request")
        self.close_connection = True
        if self.server.pause == "after_binding":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            created = {"type": "response.created", "response": {
                "id": "resp_1", "object": "response", "status": "in_progress",
                "model": payload["model"], "output": [], "usage": None,
            }}
            self.wfile.write(b"data: " + json.dumps(created).encode() + b"\n\n")
            self.wfile.flush()
        self.server.received.set()
        self.server.release.wait(timeout=20)


def ledger(database):
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        attempts = [dict(row) for row in db.execute("""
            SELECT id, principal, key_id, namespace, identity, state, reserved, window_id,
                   policy_version, pricing_version, admission_json, usage_json, estimated,
                   created_at_epoch, unknown_since_epoch, closed_unknown_at_epoch
            FROM attempts ORDER BY id
        """)]
        bindings = {tuple(row) for row in db.execute("""
            SELECT attempt, principal, namespace, identity, raw_id
            FROM bindings WHERE object_type='response'
        """)}
        evidence = {(attempt, revision): payload for attempt, revision, payload in db.execute(
            "SELECT attempt, revision, payload FROM evidence"
        )}
    return attempts, bindings, evidence


def assert_attempt(attempt, expected_state, evidence):
    require(attempt["state"] == expected_state,
            f"expected {expected_state}, found {attempt['state']}")
    require(tuple(attempt[key] for key in ("principal", "key_id", "identity")) == OWNER
            and re.fullmatch(r"synthetic-provider:[0-9a-f]{64}", attempt["namespace"]),
            "execution owner changed")
    require(attempt["reserved"] == 10 and attempt["closed_unknown_at_epoch"] is None,
            "execution lost its original reservation or was closed")
    require((attempt["unknown_since_epoch"] is not None) == (expected_state == "unknown"),
            "execution has an unexpected unknown-since timestamp")
    if expected_state == "settled":
        usage = json.loads(attempt["usage_json"] or "{}")
        require(all(usage.get(name) == value for name, value in USAGE.items())
                and attempt["estimated"] == 8 and evidence == {usage["revision"]: usage},
                "settlement evidence changed")
    else:
        require(attempt["usage_json"] is None and attempt["estimated"] == 0 and not evidence,
                "interrupted execution acquired usage or settlement evidence")


def attempt_evidence(evidence, attempt_id):
    return {revision: json.loads(payload) for (owner, revision), payload in evidence.items()
            if owner == attempt_id}


def response_binding(attempt, response_id):
    return tuple(attempt[key] for key in ("id", "principal", "namespace", "identity")) + (response_id,)


def initial_snapshot(database, phase, state):
    attempts, bindings, evidence = ledger(database)
    if phase == "before_intent":
        require(not (attempts or bindings or evidence), "idle gateway recorded an execution")
        return None
    require(len(attempts) == 1, "expected exactly one original attempt")
    attempt = attempts[0]
    require(all(owner == attempt["id"] for owner, _ in evidence),
            "found evidence for an unrelated attempt")
    assert_attempt(attempt, state, attempt_evidence(evidence, attempt["id"]))
    owned = response_binding(attempt, "resp_1")
    require(bindings == ({owned} if phase in ("after_binding", "after_settlement") else set()),
            "unexpected durable response ownership")
    return attempt


def files(database):
    return [database.with_name(database.name + suffix) for suffix in SUFFIXES]


def assert_private(database):
    for file in files(database):
        require(file.exists() and stat.S_IMODE(file.stat().st_mode) == 0o600,
                f"{file.name} mode did not narrow to 0600")


def pause_request(client, upstream):
    client.request("POST", "/v1/responses", json.dumps({
        "model": "synthetic-text", "input": "synthetic interrupted turn", "stream": True,
    }), {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    require(upstream.received.wait(timeout=5), "gateway did not reach upstream")
    if upstream.pause == "after_binding":
        response = client.getresponse()
        require(response.status == 200, "gateway did not open an SSE response")
        line = response.readline(65537)
        if line == b"event: response.created\n":
            line = response.readline(65537)
        require(line.startswith(b"data: ") and len(line) <= 65536, "missing initial SSE event")
        event = json.loads(line[6:])
        require(event.get("type") == "response.created" and event["response"]["id"] == "resp_1",
                "gateway did not expose the expected response ID")


def wait_for_settlement(database):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        attempts, _, _ = ledger(database)
        if len(attempts) == 1 and attempts[0]["state"] == "settled":
            return
        time.sleep(0.02)
    require(False, "completed response did not persist settlement")


def verify(binary, root, phase):
    dispatched = int(phase != "before_intent")
    before_state = "settled" if phase == "after_settlement" else "intent"
    after_state = "unknown" if before_state == "intent" else before_state
    with fixture(root, handler=PausedUpstream, execution_timeout=15) as (upstream, database, environment):
        upstream.pause = phase if phase in ("after_intent", "after_binding") else None
        upstream.received = threading.Event()
        upstream.release = threading.Event()
        with closing(http.client.HTTPConnection("127.0.0.1", timeout=5)) as client:
            try:
                with running_gateway(binary, root, environment, crash=True) as ports:
                    health(ports)
                    assert_private(database)
                    if upstream.pause:
                        client.port = ports["data"]
                        pause_request(client, upstream)
                    elif dispatched:
                        generate(ports["data"], 1)
                        wait_for_settlement(database)
                    original = initial_snapshot(database, phase, before_state)
                    require(upstream.calls == dispatched, "unexpected dispatch before crash")
            finally:
                upstream.release.set()
        require(initial_snapshot(database, phase, before_state) == original,
                "SIGKILL did not leave the same committed SQLite state")
        for file in files(database):
            if file.exists():
                file.chmod(0o644)

        with running_gateway(binary, root, environment) as ports:
            health(ports)
            assert_private(database)
            recovered = initial_snapshot(database, phase, after_state)
            expected = original
            if original is not None and after_state == "unknown":
                expected = dict(original, state="unknown", unknown_since_epoch=recovered["unknown_since_epoch"])
                require(recovered["unknown_since_epoch"] >= original["created_at_epoch"],
                        "recovery has an invalid timestamp")
            require(recovered == expected and upstream.calls == dispatched,
                    "restart rewrote the original attempt or dispatched it again")
            port = ports["data"]
            if phase == "after_intent":
                denied = request(port, "/v1/responses", {
                    "model": "synthetic-text", "input": "synthetic turn 2",
                    "previous_response_id": "resp_1", "stream": False,
                })
                require(denied["status"] in (400, 403) and upstream.calls == dispatched,
                        "an unbound response could dispatch a continuation")
            previous = "resp_1" if phase in ("after_binding", "after_settlement") else None
            generate(port, dispatched + 1, previous=previous)

        attempts, bindings, evidence = ledger(database)
        require(len(attempts) == dispatched + 1 and upstream.calls == dispatched + 1,
                "expected exactly one new attempt and one new provider call")
        by_id = {attempt["id"]: attempt for attempt in attempts}
        require(all(owner in by_id for owner, _ in evidence), "found evidence for an unrelated attempt")
        if recovered is not None:
            require(by_id.pop(recovered["id"], None) == recovered,
                    "new execution changed the recovered attempt")
            assert_attempt(recovered, after_state, attempt_evidence(evidence, recovered["id"]))
        new = next(iter(by_id.values()))
        assert_attempt(new, "settled", attempt_evidence(evidence, new["id"]))
        expected_bindings = {response_binding(new, f"resp_{dispatched + 1}")}
        if previous is not None:
            expected_bindings.add(response_binding(recovered, previous))
        require(bindings == expected_bindings, "response ownership changed after the new request")

        with running_gateway(binary, root, environment) as ports:
            health(ports)
            require(upstream.calls == dispatched + 1, "graceful restart dispatched a prior request")
        require(ledger(database) == (attempts, bindings, evidence),
                "graceful restart changed the recovered ledger")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="codexone-execution-recovery-") as directory:
        for phase in PHASES:
            try:
                verify(binary, Path(directory).resolve() / phase, phase)
            except ProbeError as error:
                parser.exit(1, f"FAIL: SIGKILL {phase}: {error}\n")
            print(f"PASS: SIGKILL {phase}; ledger, ownership and dispatch across both restarts", flush=True)


if __name__ == "__main__":
    main()
