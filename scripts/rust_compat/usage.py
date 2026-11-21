#!/usr/bin/env python3
"""Compare Swift and Rust usage HTTP on copies of a synthetic Swift v19 database."""
import argparse
from contextlib import closing
from difflib import unified_diff
import http.client
import json
import os
from pathlib import Path
import secrets
import shutil
import sqlite3
import sys
import tempfile
import time

from compare import TOKEN, fixture, generate, require, running_gateway

MIB = 1024 * 1024


def request(port, path, headers=None, payload=None):
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
        connection.request("GET" if payload is None else "POST", path,
                           json.dumps(payload) if payload is not None else None, headers or {})
        response = connection.getresponse()
        body = response.read(MIB + 1)
        require(len(body) <= MIB, f"oversized response for {path}")
        return response.status, json.loads(body), response.getheader("Set-Cookie")


def get(port, path, headers):
    status, body, _ = request(port, path, headers)
    require(status == 200, f"{path}: expected 200, received {status}")
    return body


def probe(ports, token, paths):
    port = ports["admin"]
    headers = {"Authorization": f"Bearer {token}"}
    reports = {path: get(port, path, headers) for path in paths}
    require(request(port, "/api/usage/daily")[0] == 401, "usage allowed without authentication")
    require(request(port, "/api/usage/daily?days=32", headers)[0] == 400, "accepted invalid day window")
    for credential, expected in [(None, 401), (token, 401), (TOKEN, 404)]:
        authentication = None if credential is None else {"Authorization": f"Bearer {credential}"}
        status, body, _ = request(ports["data"], "/api/usage/daily", authentication)
        require(status == expected and "buckets" not in body, f"unexpected data listener response: {status}")
    origin = f"http://127.0.0.1:{port}"
    browser = {"Origin": origin, "Content-Type": "application/json", "Sec-Fetch-Site": "same-origin"}
    status, _, cookie = request(port, "/api/session", browser, {"username": "admin", "secret": token})
    require(status == 200 and cookie, "could not establish a browser session")
    get(port, "/api/usage/options", {"Cookie": cookie.split(";", 1)[0]})
    return reports


def pressure_round(ports, token, path):
    port = ports["admin"]
    headers = {"Authorization": f"Bearer {token}"}
    headroom = "/api/usage/headroom"
    start = get(port, headroom, headers)["storage"]
    wal = path.with_name(path.name + "-wal")
    require(start["pressure"] == "normal" and start["reserveBytes"] == 64 * MIB,
            "candidate did not report the allocated reserve")
    require(start['walBytes'] == wal.stat().st_size, "initial headroom WAL does not match disk")
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as snapshot:
        snapshot.execute("BEGIN")
        snapshot.execute("SELECT COUNT(*) FROM attempts").fetchone()
        generate(ports["data"], 2)
        for _ in range(25):
            grown = get(port, headroom, headers)["storage"]
            if grown["walBytes"] > start["walBytes"] and grown["walBytes"] == wal.stat().st_size:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("headroom did not observe the WAL grow")
    reserve = path.with_name(path.name + ".settlement-reserve")
    try:
        with reserve.open("r+b") as handle:
            handle.truncate(MIB)
            handle.flush()
            os.fsync(handle.fileno())
        storage = get(port, "/api/runtime/storage", headers)
        require(storage["pressure"] == "blocked" and storage["reserveBytes"] == MIB
                and storage["optionalWorkAllowed"] is False, "lost reserve did not block optional work")
        time.sleep(0.035)  # allow the progress gate's short sample cache to expire
        status, error, _ = request(port, headroom, headers)
        require(status == 429 and error["error"]["code"] == "usage_query_capacity",
                "headroom must not pin the WAL during storage pressure")
    finally:
        with reserve.open("r+b") as handle:
            handle.seek(MIB)
            zeros = bytes(MIB)
            for _ in range(63):
                handle.write(zeros)
            handle.flush()
            os.fsync(handle.fileno())
    time.sleep(0.035)
    recovered = get(port, headroom, headers)["storage"]
    require(recovered["pressure"] == "normal" and recovered["reserveBytes"] == 64 * MIB
            and recovered["walBytes"] == wal.stat().st_size and recovered["optionalWorkAllowed"] is True,
            "headroom did not recover in the running process")


def run(reference, candidate):
    with tempfile.TemporaryDirectory(prefix="codexone-usage-") as work:
        root = Path(work)
        with fixture(root / "reference") as (_, path, env):
            source = path.parent.parent
            token = "synthetic-" + secrets.token_hex(24)
            secret = source / "admin-token"
            secret.write_text(token, encoding="utf-8")
            secret.chmod(0o600)
            env.update(CODEXONE_ADMIN_TOKEN_FILE=str(secret), CODEXONE_BUSINESS_DAY_OFFSET="+08:00",
                       CODEXONE_ADMIN_LIVE="off")
            with running_gateway(reference, source, env) as ports:
                generate(ports["data"], 1)
            with closing(sqlite3.connect(path)) as database:
                require(database.execute("PRAGMA user_version").fetchone()[0] == 19, "expected Swift v19")
                now = database.execute("SELECT created_at_epoch FROM attempts").fetchone()[0]
                database.execute(
                    """INSERT INTO request_diagnostics(request_id, at_epoch, key_id, model, mode,
                           failure, reason, reasoning_effort)
                       VALUES ('synthetic-rejection', ?, 'synthetic-key', 'synthetic-text',
                           'generation', 'model_not_allowed', 'model_not_allowed', 'high')""", (now,))
                key = dict(id="synthetic-managed", principal="synthetic-principal", enabled=False,
                           displayName="Synthetic managed", revision=1, archivedAtUnixSeconds=now,
                           createdAtUnixSeconds=now, policy=dict(models=["synthetic-text"]))
                database.execute("INSERT INTO managed_keys VALUES (?,?,?)",
                                 (key["id"], "4" * 64, json.dumps(key)))
                database.commit()
                require(database.execute("PRAGMA wal_checkpoint(truncate)").fetchone()[0] == 0,
                        "could not checkpoint the Swift fixture")

            sandbox = root / "candidate"
            sandbox.mkdir(mode=0o700)
            state = sandbox / "state"
            state.mkdir(mode=0o700)
            target = state / "core.sqlite"
            shutil.copy2(path, target)
            rust_env = dict(env, CODEXONE_DATA_DIRECTORY=str(state), HOME=str(sandbox), TMPDIR=str(sandbox))
            hour = now // 3600 * 3600
            history = f"/api/usage?start={hour}&end={hour + 3600}"
            paths = [
                history + "&limit=1",
                history + "&rejectedOnly=true&reasoningEffort=high",
                "/api/usage/daily?days=2", "/api/usage/in-flight", "/api/usage/options",
                "/api/usage/keys", "/api/usage/keys?includeArchived=false", "/api/usage/headroom",
            ]
            with running_gateway(reference, source, env) as ports:
                swift = probe(ports, token, paths)
            with running_gateway(candidate, sandbox, rust_env) as ports:
                rust = probe(ports, token, paths)
                pressure_round(ports, token, target)
            for reports in (swift, rust):
                headroom = reports["/api/usage/headroom"]
                # Compare instance-specific observations in pressure_round, against the live filesystem.
                del headroom["storage"], headroom["generatedAtUnixSeconds"]
                del headroom["unknownReconciliation"]["beforeUnixSeconds"]
            if swift != rust:
                pretty = lambda value: json.dumps(value, sort_keys=True, indent=2).splitlines(True)
                sys.stderr.writelines(unified_diff(pretty(swift), pretty(rust), "Swift", "Rust"))
                raise AssertionError("management documents differ")
            print("PASS: eight Swift/Rust usage responses, browser and bearer authorization, data-port status parity")
            print("PASS: headroom observes WAL growth; reserve loss and recovery without restart")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=lambda arg: Path(arg).resolve(), required=True)
    parser.add_argument("--candidate", type=lambda arg: Path(arg).resolve(), required=True)
    args = parser.parse_args()
    run(args.reference, args.candidate)
