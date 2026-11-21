#!/usr/bin/env python3
"""Verify real HTTP settlement between SQLite backup batches, using synthetic data."""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

from compare import OUTPUT_LIMIT, ProbeError, fixture, generate, health, ledger, listener_ports
from compare import require, running_gateway
from maintenance import run


REPO = Path(__file__).resolve().parents[2]
GATEWAY = REPO / "rust/gateway"
PROBE_TEST = "online_backup::tests::serve_backup_probe"


def build(target):
    options = ["--locked", "--manifest-path", str(GATEWAY / "Cargo.toml"),
               "--target-dir", str(target), "--bin", "codexone"]
    subprocess.run(["cargo", "build", *options], check=True)
    messages = subprocess.check_output(
        ["cargo", "test", *options, "--no-run", "--message-format=json"], text=True
    )
    for line in messages.splitlines():
        event = json.loads(line)
        if (event.get("reason") == "compiler-artifact" and event["target"]["name"] == "codexone"
                and event["profile"]["test"] and event["executable"]):
            return target / "debug/codexone", Path(event["executable"])
    raise ProbeError("Cargo did not report the gateway test executable")


def wait_for(process, description, read):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        require(process.poll() is None, f"gateway exited before {description}")
        result = read()
        if result:
            return result
        time.sleep(0.01)
    raise ProbeError(f"timed out waiting for {description}")


def attempts(path):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
        return db.execute("SELECT id, state, usage_json FROM attempts ORDER BY rowid").fetchall()


def check_snapshot(path, before, live):
    rows = attempts(path)
    require(len(rows) in (1, 2) and rows[0] == before[0],
            "snapshot lost the already-settled request")
    if len(rows) == 2:
        latest = rows[1]
        require(latest[0] == live[1][0] and latest[1] in ("intent", "settled"),
                "snapshot captured an unexpected concurrent attempt")
        if latest[1] == "settled":
            require(latest == live[1], "snapshot captured an inconsistent settlement")
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        responses = dict(db.execute(
            "SELECT raw_id, attempt FROM bindings WHERE object_type='response'"
        ))
        require(responses.get("resp_1") == before[0][0], "snapshot lost the first response binding")
        if len(rows) == 2 and rows[1][1] == "settled":
            require(responses.get("resp_2") == live[1][0], "snapshot lost a settled response binding")
        require(db.execute("SELECT length(payload) FROM synthetic_padding").fetchall()
                == [(2 * 1024 * 1024,)], "snapshot lost committed filler pages")


def exercise(rust, swift, probe, root):
    with fixture(root) as (upstream, database, env):
        with running_gateway(rust, root, env) as ports:
            health(ports)
            generate(ports["data"], 1)
        ledger(database, 1)
        before = attempts(database)

        # A small committed filler spans multiple 128-page batches. The test waits
        # on the copy callback instead of relying on database size for timing.
        with closing(sqlite3.connect(database)) as db:
            db.execute("CREATE TABLE synthetic_padding(payload BLOB)")
            db.execute("INSERT INTO synthetic_padding VALUES(zeroblob(2097152))")
            db.commit()
            require(db.execute("PRAGMA page_count").fetchone()[0] > 128, "fixture fits in one batch")

        backups = root / "backups"
        backups.mkdir(mode=0o700)
        env.update(CODEXONE_BACKUP_DIRECTORY=str(backups), CODEXONE_TEST_ONLINE_BACKUP="1")
        with tempfile.TemporaryFile(dir=root) as output, subprocess.Popen(
            [probe, "--exact", PROBE_TEST, "--nocapture"],
            cwd=root, env=env, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT,
        ) as process:
            try:
                ports = listener_ports(process, output)
                def copied_first_batch():
                    log = os.pread(output.fileno(), OUTPUT_LIMIT, 0)
                    return b"\nONLINE_BACKUP_FIRST_BATCH\n" in log

                wait_for(process, "the first SQLite backup batch", copied_first_batch)
                require(len(list(backups.glob("online-*.partial/snapshot.sqlite.partial"))) == 1,
                        "the first batch did not leave an unfinished snapshot")
                generate(ports["data"], 2, previous="resp_1")

                def settled():
                    rows = attempts(database)
                    return rows if len(rows) == 2 and rows[1][1] == "settled" else None

                live = wait_for(process, "durable settlement while the copy is paused", settled)
                ledger(database, 2)
                require(not list(backups.glob("online-*/manifest.json")),
                        "backup was published before the paused copy resumed")
                process.stdin.write(b"continue\n")
                process.stdin.flush()

                published = wait_for(process, "a completed online bundle", lambda: [
                    path for path in backups.iterdir() if not path.name.endswith(".partial")
                ])
                require(len(published) == 1, "expected exactly one completed online bundle")
                [bundle] = published
                require(run(swift, env, "--verify-backup", bundle)
                        == run(rust, env, "--verify-backup", bundle),
                        "Swift and Rust reported different online manifests")
                check_snapshot(bundle / "snapshot.sqlite", before, live)
                process.terminate()
                require(process.wait(timeout=10) == 0, "probe gateway failed to shut down")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        require(upstream.calls == 2, "expected one upstream call per HTTP request")
        require(attempts(database) == live, "the settled ledger changed on shutdown")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True, help="Swift baseline CLI")
    parser.add_argument("--target-dir", type=Path, default=GATEWAY / "target")
    args = parser.parse_args()
    swift = args.swift.resolve(strict=True)
    rust, probe = build(args.target_dir.resolve())
    with tempfile.TemporaryDirectory(prefix="codexone-online-backup-") as temporary:
        exercise(rust, swift, probe, Path(temporary).resolve() / "gateway")
    print("HTTP settlement during SQLite backup and Swift/Rust snapshot verification passed")


if __name__ == "__main__":
    main()
