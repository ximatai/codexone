#!/usr/bin/env python3
"""Compare two CodexOne executables using fresh synthetic state."""
import argparse
from contextlib import closing, contextmanager
from difflib import unified_diff
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

# Share the synthetic provider used by the Swift process verification.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_protocol import TOKEN, Upstream

LISTENER = re.compile(rb"^LISTENING (data|admin) 127\.0\.0\.1:([0-9]{1,5})$", re.MULTILINE)
OUTPUT_LIMIT = 128 * 1024


class ProbeError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ProbeError(message)


def json_object(raw, source):
    try:
        document = json.loads(raw)
    except ValueError as error:
        raise ProbeError(f"{source} did not return valid JSON") from error
    require(isinstance(document, dict), f"{source} did not return a JSON object")
    return document


@contextmanager
def synthetic_upstream(handler=Upstream, *, port=0):
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
        server.guard = threading.Lock()
        server.calls = 0
        thread = threading.Thread(target=server.serve_forever, args=(0.05,))
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def listener_ports(process, output):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        require(process.poll() is None, f"gateway exited during startup ({process.returncode})")
        raw = os.pread(output.fileno(), OUTPUT_LIMIT + 1, 0)
        require(len(raw) <= OUTPUT_LIMIT, "gateway exceeded startup output limit")
        ports = {name.decode(): int(port) for name, port in LISTENER.findall(raw)}
        if ports.keys() == {"data", "admin"}:
            require(len(set(ports.values())) == 2 and all(0 < p < 65536 for p in ports.values()),
                    "gateway reported invalid listener ports")
            return ports
        time.sleep(0.02)
    raise ProbeError("gateway did not announce both loopback ports within 20 seconds")


@contextmanager
def running_gateway(binary, root, environment):
    with tempfile.TemporaryFile(dir=root) as output:
        process = subprocess.Popen([binary], cwd=root, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            yield listener_ports(process, output)
            require(process.poll() is None, "gateway exited before graceful shutdown")
            process.terminate()
            try:
                status = process.wait(timeout=10)
            except subprocess.TimeoutExpired as error:
                raise ProbeError("gateway did not shut down within 10 seconds") from error
            require(status == 0, f"gateway shutdown failed ({status})")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


def request(port, path, payload=None):
    method = "GET" if payload is None else "POST"
    headers = {}
    if payload is not None:
        headers = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
    with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
        try:
            connection.request(method, path, json.dumps(payload) if payload is not None else None, headers)
            response = connection.getresponse()
            body = response.read(OUTPUT_LIMIT + 1)
            require(len(body) <= OUTPUT_LIMIT, f"{method} {path} exceeded response limit")
            return {"status": response.status, "body": json_object(body, f"{method} {path}")}
        except (OSError, http.client.HTTPException) as error:
            raise ProbeError(f"{method} {path} failed ({type(error).__name__})") from error


def health(ports):
    result = {}
    for listener, port in ports.items():
        live = request(port, "/health/live")
        ready = request(port, "/health/ready")
        require(live["status"] == 200 and live["body"].get("status") == "alive", f"{listener} is not live")
        require(ready["status"] == 200 and ready["body"].get("ready") is True, f"{listener} is not ready")
        result[listener] = {"live": live, "ready": ready}
    return result


def generate(port, turn, previous=None):
    payload = {"model": "synthetic-text", "input": f"synthetic turn {turn}", "stream": False}
    if previous is not None:
        payload["previous_response_id"] = previous
    response = request(port, "/v1/responses", payload)
    body = response["body"]
    require(response["status"] == 200 and body.get("status") == "completed",
            f"turn {turn} did not complete (HTTP {response['status']})")
    require(body.get("id") == f"resp_{turn}", f"turn {turn} returned an unexpected response ID")
    if previous is not None:
        require(body.get("previous_response_id") == previous, "continuation lost its previous response ID")
    return response


def ledger(path, expected_attempts):
    # Read after graceful shutdown and never create or mutate the candidate's database.
    try:
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
            version = db.execute("PRAGMA user_version").fetchone()[0]
            rows = db.execute("SELECT state, usage_json FROM attempts ORDER BY rowid LIMIT ?",
                              (expected_attempts + 1,)).fetchall()
    except sqlite3.Error as error:
        raise ProbeError(f"could not read the ledger after turn {expected_attempts} ({type(error).__name__})") from error
    require(version > 0, "database did not record a schema version")
    require(len(rows) == expected_attempts, f"expected {expected_attempts} ledger attempts")
    attempts = []
    for state, encoded in rows:
        require(state == "settled" and encoded is not None, "ledger attempt did not settle")
        require(isinstance(encoded, (str, bytes)), "ledger usage is not JSON text")
        usage = json_object(encoded, "ledger usage")
        expected = {"inputTokens": 5, "outputTokens": 3, "estimatedMicros": 8}
        require(all(usage.get(name) == value for name, value in expected.items()), "ledger usage differs from fixture")
        attempts.append({"state": state, "usage": usage})
    return {"schemaVersion": version, "attempts": attempts}


@contextmanager
def fixture(root, *, handler=Upstream):
    root.mkdir(mode=0o700)
    config = root / "identity.json"
    database = root / "state" / "core.sqlite"
    environment = {
        "PATH": os.defpath, "HOME": str(root), "TMPDIR": str(root),
        "CODEXONE_DATA_PORT": "0", "CODEXONE_ADMIN_PORT": "0",
        "CODEXONE_IDENTITY_CONFIG": str(config),
        "CODEXONE_DATA_DIRECTORY": str(database.parent),
    }
    with synthetic_upstream(handler) as upstream:
        config.write_text(json.dumps({
            "principal": "synthetic-principal", "keyID": "synthetic-key",
            "keySHA256": hashlib.sha256(TOKEN.encode()).hexdigest(),
            "namespace": "synthetic-provider", "identity": "synthetic-account",
            "reservedMicros": 10, "executionTimeoutSeconds": 5,
            "models": [{"id": "synthetic-text", "inputMicrosPerMillion": 1000000,
                        "outputMicrosPerMillion": 1000000}],
            "upstreamBaseURL": f"http://127.0.0.1:{upstream.server_port}/v1",
        }), encoding="utf-8")
        config.chmod(0o600)
        yield upstream, database, environment


def probe(binary, root, restart_with=None):
    with fixture(root) as (upstream, database, environment):
        try:
            checked = subprocess.run([binary, "--check-config"], cwd=root, env=environment,
                                     stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        except subprocess.TimeoutExpired as error:
            raise ProbeError("--check-config did not finish within 10 seconds") from error
        require(checked.returncode == 0, f"--check-config exited {checked.returncode}")
        configuration = json_object(checked.stdout, "--check-config")
        require(not database.exists() and upstream.calls == 0,
                "--check-config touched the database or called the upstream")

        with running_gateway(binary, root, environment) as ports:
            initial_health = health(ports)
            first = generate(ports["data"], 1)
        require(upstream.calls == 1, "expected one upstream call after the first shutdown")
        initial_ledger = ledger(database, 1)

        with running_gateway(restart_with or binary, root, environment) as ports:
            restarted_health = health(ports)
            second = generate(ports["data"], 2, previous=first["body"]["id"])
        require(upstream.calls == 2, "expected exactly two upstream calls after restart")
        restarted_ledger = ledger(database, 2)

    return {
        "checkConfig": configuration,
        "initial": {"health": initial_health, "response": first, "ledger": initial_ledger, "upstreamCalls": 1},
        "restarted": {"health": restarted_health, "response": second, "ledger": restarted_ledger, "upstreamCalls": 2},
    }


def snapshot(report):
    return json.dumps(report, sort_keys=True, indent=2, allow_nan=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True, help="baseline backend executable")
    parser.add_argument("--candidate", type=Path, required=True, help="backend executable under comparison")
    args = parser.parse_args()

    reports = {}
    failures = {}
    with tempfile.TemporaryDirectory(prefix="codexone-rust-compat-") as temporary:
        runs = (
            ("reference", args.reference, None),
            ("candidate", args.candidate, None),
            ("reference-to-candidate", args.reference, args.candidate),
            ("candidate-to-reference", args.candidate, args.reference),
        )
        for role, binary, restart_with in runs:
            try:
                reports[role] = snapshot(probe(
                    binary.resolve(strict=True),
                    Path(temporary).resolve() / role,
                    restart_with.resolve(strict=True) if restart_with else None,
                ))
            except ProbeError as error:
                failures[role] = str(error)
            except (OSError, ValueError) as error:
                failures[role] = f"probe failed ({type(error).__name__})"

    for role, error in failures.items():
        print(f"{role}: {error}", file=sys.stderr)
    if failures:
        return 2
    reference = reports.pop("reference")
    differences = {role: actual for role, actual in reports.items() if reference != actual}
    for role, actual in differences.items():
        sys.stderr.writelines(unified_diff(reference.splitlines(keepends=True),
                                           actual.splitlines(keepends=True),
                                           fromfile="reference", tofile=role))
    if differences:
        return 1
    sys.stdout.write(reference)
    return 0


if __name__ == "__main__":
    sys.exit(main())
