#!/usr/bin/env python3
"""Check storage observation and, on a private Linux tmpfs, real ENOSPC recovery."""
import argparse
from contextlib import closing, contextmanager
import errno
import http.client
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import stat
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

import verify_admin
from verify_admin import ADMIN, document, request, running_admin
from verify_keys import create, update
from verify_protocol import current_schema_version
from verify_snapshot_restore import ready, request as generate, stopped

MIB = 1024 * 1024
STORAGE_ROUTE = "/api/runtime/storage"
ADMIN_HEADERS = {"Authorization": "Bearer " + ADMIN}


def observation(fixture):
    return document(request(fixture.ports["admin"], "GET", STORAGE_ROUTE, headers=ADMIN_HEADERS))


def until(predicate, *, timeout=6):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, "Storage state did not converge"
        time.sleep(0.05)


def available(directory):
    info = os.statvfs(directory)
    return info.f_bavail * info.f_frsize


def require_private_tmpfs(root):
    assert sys.platform == "linux" and root.is_mount(), "Expected a dedicated Linux tmpfs mount"
    assert subprocess.check_output(["stat", "-f", "-c", "%T", root]).strip() == b"tmpfs"
    metadata = root.stat()
    assert metadata.st_uid == os.geteuid() and stat.S_IMODE(metadata.st_mode) == 0o700
    info = os.statvfs(root)
    assert 384 * MIB <= info.f_blocks * info.f_frsize <= 512 * MIB, "Expected a 384–512 MiB tmpfs"
    assert not any(root.iterdir()), "Expected an empty, private tmpfs"


def fill(file, directory, target):
    block = bytes(MIB)
    while (remaining := available(directory) - target) > 0:
        try:
            assert file.write(block[:min(MIB, remaining)]) > 0
        except OSError as error:
            if target == 0 and error.errno == errno.ENOSPC:
                return
            raise
    if target == 0:
        try:
            file.write(block)
        except OSError as error:
            if error.errno == errno.ENOSPC:
                return
            raise
        raise AssertionError("Expected an actual ENOSPC write failure")


def command(binary, state, *arguments, admin=None, master=None, rejected=False):
    environment = {"PATH": os.defpath, "CODEXONE_DATA_DIRECTORY": str(state)}
    if admin:
        environment["CODEXONE_ADMIN_TOKEN_FILE"] = str(admin)
    if master:
        environment["CODEXONE_ACCOUNT_MASTER_KEY_FILE"] = str(master)
    result = subprocess.run([binary, *map(str, arguments)], capture_output=True, timeout=30, env=environment)
    output = result.stdout + result.stderr
    assert len(output) < 32768 and str(state.parent).encode() not in output
    assert (result.returncode != 0) == rejected, "Unexpected maintenance command result"


class PressureUpstream(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        item = {"id": f"msg_{index}", "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "synthetic", "annotations": []}]}
        response = {"id": f"resp_{index}", "object": "response", "status": "completed",
                    "model": payload["model"], "output": [item],
                    "usage": {"input_tokens": 5, "output_tokens": 3,
                              "input_tokens_details": {"cached_tokens": 0}}}
        self.send_response(200)
        if payload.get("stream"):
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.send_event("response.created", {**response, "status": "in_progress", "output": [], "usage": None})
            self.server.entered.set()
            if self.server.release.wait(timeout=25):
                self.send_event("response.completed", response)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
        else:
            body = json.dumps(response).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def send_event(self, kind, response):
        self.wfile.write(b"data: " + json.dumps({"type": kind, "response": response}).encode() + b"\n\n")
        self.wfile.flush()


@contextmanager
def held_stream(fixture, secret):
    fixture.provider.entered.clear()
    fixture.provider.release.clear()
    try:
        with closing(http.client.HTTPConnection("127.0.0.1", fixture.ports["data"], timeout=15)) as client:
            client.request("POST", "/v1/responses", json.dumps({
                "model": "synthetic-text", "input": "synthetic held stream", "stream": True,
            }), {"Authorization": "Bearer " + secret, "Content-Type": "application/json"})
            with closing(client.getresponse()) as response:
                assert response.status == 200 and fixture.provider.entered.wait(timeout=5)
                line = response.readline(65537)
                if line == b"event: response.created\n":
                    line = response.readline(65537)
                assert line.startswith(b"data: ") and json.loads(line[6:])["type"] == "response.created"
                yield response
    finally:
        fixture.provider.release.set()


def assert_denied(fixture, secret):
    for port in fixture.ports.values():
        assert ready(port) == 503
        assert request(port, "GET", "/health/live")[0] == 200
    before = fixture.provider.calls
    status, body = generate(fixture.ports["data"], secret)
    assert status == 503 and json.loads(body)["error"]["code"] == "storage_pressure"
    assert fixture.provider.calls == before


def disk_pressure(fixture):
    fixture.provider.entered = threading.Event()
    fixture.provider.release = threading.Event()
    _, secret = create(fixture.ports["admin"], principal="synthetic-storage")
    revocable, other_secret = create(fixture.ports["admin"], principal="synthetic-revocable")
    fixture.secrets.extend([secret, other_secret])
    filler = fixture.root / "pressure-filler"

    with held_stream(fixture, secret) as response, filler.open("wb", buffering=0) as file:
        fill(file, fixture.root, 200 * MIB)
        until(lambda: observation(fixture)["pressure"] == "degraded")
        assert ready(fixture.ports["admin"]) == 200
        assert update(fixture.ports["admin"], revocable, enabled=False)[0] == 200
        assert request(fixture.ports["admin"], "GET", "/api/usage/options", headers=ADMIN_HEADERS)[0] == 503
        assert generate(fixture.ports["data"], secret)[0] == 200
        fill(file, fixture.root, 100 * MIB)
        until(lambda: observation(fixture)["pressure"] == "blocked")
        assert_denied(fixture, secret)

        # Releasing space below the resume watermark must never reopen admission.
        file.truncate(file.tell() - (160 * MIB - available(fixture.root)))
        file.seek(0, os.SEEK_END)
        assert 128 * MIB <= available(fixture.root) < 192 * MIB
        assert_denied(fixture, secret)

        fill(file, fixture.root, 0)
        assert_denied(fixture, secret)
        fixture.provider.release.set()
        assert b"response.completed" in response.read()
        until(lambda: observation(fixture)["reserveBytes"] < 64 * MIB)
        sample = observation(fixture)
        assert sample["coreAvailable"] and not sample["admissionAllowed"]

        def all_settled():
            database = fixture.root / "state/core.sqlite"
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
                return db.execute(
                    "SELECT count(*),sum(state='settled'),sum(json_extract(usage_json,'$.inputTokens')) FROM attempts"
                ).fetchone() == (2, 2, 10)

        until(all_settled)
    filler.unlink()
    # Rust replenishes the reserve on the gateway's 30-second maintenance interval.
    until(lambda: observation(fixture)["pressure"] == "normal", timeout=40)
    assert observation(fixture)["reserveBytes"] == 64 * MIB
    assert ready(fixture.ports["admin"]) == 200 and generate(fixture.ports["data"], secret)[0] == 200
    print("PASS: degraded, blocked and hysteresis watermarks, actual ENOSPC, in-flight settlement and reserve recovery", flush=True)


def offline_pressure(binary, fixture):
    stopped(fixture.process)
    fixture.process = None
    state = fixture.root / "state"
    bundle = fixture.root / "normal-backup"
    command(binary, state, "--backup", bundle)
    master = fixture.root / "synthetic-master"
    master.write_text("5a" * 32)
    master.chmod(0o600)
    database = state / "core.sqlite"
    schema = current_schema_version(binary)
    filler = fixture.root / "pressure-filler"
    with filler.open("wb", buffering=0) as file:
        fill(file, fixture.root, 100 * MIB)
        command(binary, state, "--backup", fixture.root / "refused-backup", rejected=True)
        command(binary, fixture.root / "refused-restore", "--restore", bundle, rejected=True)
        command(binary, state, "--reencrypt-credentials", fixture.root / "refused-rekey",
                admin=fixture.admin, master=master, rejected=True)
        # Reconstruct the preceding compatible schema so migration can succeed after space returns.
        with closing(sqlite3.connect(database)) as db, db:
            db.execute("ALTER TABLE request_diagnostics DROP COLUMN reasoning_effort")
            db.execute("PRAGMA user_version=18")
        command(binary, state, "--migrate", rejected=True)
        assert not any(fixture.root.glob("refused-*")) and not list(state.glob("*.pre-v*"))
        with closing(sqlite3.connect(database)) as db:
            assert db.execute("PRAGMA user_version").fetchone() == (18,)
    filler.unlink()
    command(binary, state, "--migrate")
    with closing(sqlite3.connect(database)) as db:
        assert db.execute("PRAGMA user_version").fetchone() == (schema,)
    assert len(list(state.glob("*.pre-v*.sqlite"))) == 1
    command(binary, state, "--verify-backup", bundle)
    command(binary, fixture.root / "restored", "--restore", bundle)
    command(binary, state, "--reencrypt-credentials", fixture.root / "normal-rekey",
            admin=fixture.admin, master=master)
    print("PASS: low-space offline backup, restore, rekey and migration refusal, with intact backup and retry", flush=True)


def verify(binary, space_root):
    with running_admin(binary) as fixture:
        assert request(fixture.ports["admin"], "GET", STORAGE_ROUTE)[0] == 401
        sample = observation(fixture)
        assert sample["pressure"] == "normal" and sample["admissionAllowed"] and sample["optionalWorkAllowed"]
        reserve = (fixture.root / "state/core.sqlite.settlement-reserve").stat()
        assert stat.S_IMODE(reserve.st_mode) == 0o600 and reserve.st_blocks * 512 >= 64 * MIB
        assert sample["reserveBytes"] == sample["reserveTargetBytes"] == 64 * MIB
        assert sample["peakResidentBytes"] > 0 and 0 < sample["observedFDs"] <= sample["fdScanLimit"] == 1024
        assert str(fixture.root) not in json.dumps(sample) and "synthetic" not in json.dumps(sample)
        print("PASS: authenticated no-store storage observation and private physically allocated reserve", flush=True)

        if space_root:
            disk_pressure(fixture)
            offline_pressure(binary, fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--space-root", type=Path, help="empty dedicated Linux tmpfs of 384–512 MiB")
    args = parser.parse_args()
    try:
        binary = str(args.binary.resolve(strict=True))
        if args.space_root:
            space_root = args.space_root.resolve(strict=True)
            require_private_tmpfs(space_root)
            with patch.object(tempfile, "tempdir", str(space_root)), patch.object(verify_admin, "Upstream", PressureUpstream):
                verify(binary, space_root)
        else:
            verify(binary, None)
    except Exception as error:
        trace = error.__traceback__
        while trace.tb_next:
            trace = trace.tb_next
        location = Path(trace.tb_frame.f_code.co_filename).name + ":" + str(trace.tb_lineno)
        print(f"FAIL: storage pressure verification at {location} ({type(error).__name__}); private values withheld",
              file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
