#!/usr/bin/env python3
"""Exercise the Rust gateway's admission readiness using synthetic storage faults."""
import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import time

from compare import fixture, generate, health, request, running_gateway


def execution_ready(report):
    return next(check["ready"] for check in report["body"]["checks"]
                if check["name"] == "execution_store")


def assert_blocked(ports):
    for port in ports.values():
        assert request(port, "/health/live") == {"status": 200, "body": {"status": "alive"}}
        ready = request(port, "/health/ready")
        assert ready["status"] == 503 and ready["body"]["ready"] is False
        assert execution_ready(ready) is False
    system = request(ports["admin"], "/api/system")
    assert system["status"] == 200 and execution_ready(system) is False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    binary = parser.parse_args().binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="codexone-rust-readiness-") as temporary:
        root = Path(temporary).resolve() / "gateway"
        with fixture(root) as (upstream, database, environment):
            with running_gateway(binary, root, environment) as ports:
                health(ports)
                with database.with_name("core.sqlite.settlement-reserve").open("r+b") as reserve:
                    reserve.truncate(0)
                assert_blocked(ports)
                denied = request(ports["data"], "/v1/responses", {
                    "model": "synthetic-text", "input": "synthetic storage pressure", "stream": False,
                })
                assert denied["status"] == 503 and denied["body"]["error"]["code"] == "storage_pressure"
                assert upstream.calls == 0
            with running_gateway(binary, root, environment) as ports:
                health(ports)
                generate(ports["data"], 1)
                assert upstream.calls == 1
            print("PASS: reserve loss blocks readiness and dispatch, live stays healthy, restart resumes")

            # Seed a reconciled snapshot that is still frozen. The Rust gateway requires
            # managed Keys after restore, so start its storage-only mode to inspect the gate.
            now = int(time.time())
            restore_id = "00000000-0000-0000-0000-000000000001"
            restore = {
                "id": restore_id, "backupID": "00000000-0000-0000-0000-000000000002",
                "snapshotUnixSeconds": now - 1, "restoredUnixSeconds": now,
                "inheritedUnresolvedRequests": 0, "inheritedUnresolvedMicros": 0,
                "inheritedFreezeUntilUnixSeconds": 0, "dayFreezeUntilUnixSeconds": now + 60,
                "baselineRevision": 1, "reconciledUnixSeconds": now,
                "baseline": {
                    "restoreID": restore_id, "expectedRevision": 0, "auditReference": "synthetic",
                    "missingUnresolvedRequests": 0, "missingUnresolvedMicros": 0,
                    "freezeUntilUnixSeconds": now + 60,
                },
            }
            with closing(sqlite3.connect(database)) as db, db:
                db.execute("UPDATE maintenance_state SET restore_json=? WHERE id=1", (json.dumps(restore),))
            environment.pop("CODEXONE_IDENTITY_CONFIG")
            with running_gateway(binary, root, environment) as ports:
                assert_blocked(ports)
            assert upstream.calls == 1
            print("PASS: reconciled but frozen restore blocks the execution readiness check")


if __name__ == "__main__":
    main()
