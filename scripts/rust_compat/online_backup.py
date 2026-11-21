#!/usr/bin/env python3
"""Verify real HTTP settlement between SQLite backup batches, using synthetic data."""

import argparse
from contextlib import closing, contextmanager
import fcntl
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
from overview import Socket, log_in
from usage import get


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


@contextmanager
def running_backup_probe(probe, root, env):
    with tempfile.TemporaryFile(dir=root) as output, subprocess.Popen(
        [probe, "--exact", PROBE_TEST, "--nocapture"],
        cwd=root, env=env, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT,
    ) as process:
        try:
            ports = listener_ports(process, output)
            wait_for(process, "the first SQLite backup batch", lambda: (
                b"\nONLINE_BACKUP_FIRST_BATCH\n" in os.pread(output.fileno(), OUTPUT_LIMIT, 0)
            ))

            def resume():
                process.stdin.write(b"continue\n")
                process.stdin.flush()

            yield process, ports, resume
            process.terminate()
            require(process.wait(timeout=10) == 0, "probe gateway failed to shut down")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


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
        with running_backup_probe(probe, root, env) as (process, ports, resume):
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
            resume()

            published = wait_for(process, "a completed online bundle", lambda: [
                path for path in backups.iterdir() if not path.name.endswith(".partial")
            ])
            require(len(published) == 1, "expected exactly one completed online bundle")
            [bundle] = published
            manifest = run(rust, env, "--verify-backup", bundle)
            if swift:
                require(run(swift, env, "--verify-backup", bundle) == manifest,
                        "Swift and Rust reported different online manifests")
            check_snapshot(bundle / "snapshot.sqlite", before, live)
        require(upstream.calls == 2, "expected one upstream call per HTTP request")
        require(attempts(database) == live, "the settled ledger changed on shutdown")


def health_and_rotation(rust, probe, root):
    storage_path = "/api/runtime/storage"
    with fixture(root) as (_, database, env):
        token = "synthetic-admin-secret-for-backup-health"
        secret = root / "admin-token"
        secret.write_text(token, encoding="utf-8")
        secret.chmod(0o600)
        env["CODEXONE_ADMIN_TOKEN_FILE"] = str(secret)
        headers = {"Authorization": f"Bearer {token}"}
        with running_gateway(rust, root, env) as ports:
            disabled = get(ports["admin"], storage_path, headers)["backup"]
            require(disabled["enabled"] is False and disabled["retainedCount"] == 0,
                    "disabled backup status is missing")

        workspace = root / "workspace"
        workspace.mkdir(mode=0o700)
        alias = root / "alias"
        alias.symlink_to(workspace, target_is_directory=True)
        backups = workspace / "backups"
        backups.mkdir(mode=0o700)
        backup_link = root / "backup-link"
        backup_link.symlink_to(backups, target_is_directory=True)
        refused = subprocess.run([rust, "--check-config"], env={
            **env, "CODEXONE_BACKUP_DIRECTORY": str(backup_link) + "/",
        }, capture_output=True, timeout=10)
        require(refused.returncode != 0 and b"Invalid backup directory" in refused.stderr,
                "accepted a backup root ending in a directory symlink")
        env["CODEXONE_BACKUP_DIRECTORY"] = str(alias / "backups")
        env["CODEXONE_TEST_ONLINE_BACKUP"] = "1"

        manual = backups / "manual"
        run(rust, env, "--backup", manual)
        start = int(time.time()) - 73 * 3600
        previous = []
        for index in range(7):
            staged = workspace / "staged"
            manifest = run(rust, env, "--backup", staged)
            created = start + index
            manifest["createdUnixSeconds"] = created
            (staged / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            bundle = backups / f"online-{created * 1000000}-{manifest['id']}"
            staged.rename(bundle)
            previous.append(bundle)

        with closing(sqlite3.connect(database)) as db:
            db.execute("CREATE TABLE synthetic_padding(payload BLOB)")
            db.execute("INSERT INTO synthetic_padding VALUES(zeroblob(2097152))")
            db.commit()

        def status_at(ports):
            return get(ports["admin"], storage_path, headers)["backup"]

        def retention_failed(ports):
            status = status_at(ports)
            if status.get("lastFailure") == "retention_failed" and status["retainedCount"] == 8:
                return status
            return None

        with running_backup_probe(probe, root, env) as (process, ports, resume):
            initial = status_at(ports)
            require(initial["lastSuccessUnixSeconds"] == start + 6 and initial["retainedCount"] == 7,
                    "startup did not recover the last successful backup")
            attention = get(ports["admin"], "/api/attention", headers)["items"]
            require(any(item["kind"] == "backup_stale" and item["severity"] == "critical"
                        for item in attention), "restored backup time did not drive the critical reminder")
            reserve = database.with_name(database.name + ".settlement-reserve")
            with reserve.open("r+b") as file:
                file.truncate(1024 * 1024)
                # The backup pressure cache can reuse a reading for up to 500 ms.
                time.sleep(0.55)
                resume()
                wait_for(process, "backup skipped under storage pressure", lambda: (
                    status_at(ports).get("skippedPressure") == "blocked"
                ))
                skipped = status_at(ports)
                require(skipped["lastSkippedUnixSeconds"] >= skipped["enabledUnixSeconds"]
                        and "lastFailure" not in skipped and skipped["retainedCount"] == 7,
                        "backup pressure was not reported independently of failure")
                file.seek(1024 * 1024)
                for _ in range(63):
                    file.write(bytes(1024 * 1024))
                file.flush()
                os.fsync(file.fileno())
            require(all(bundle.is_dir() for bundle in previous), "pressure removed completed backups")

        with (previous[0] / "snapshot.sqlite.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with running_backup_probe(probe, root, env) as (process, ports, resume):
                require("skippedPressure" not in status_at(ports), "skip state survived restart")
                resume()
                failed = wait_for(process, "retirement blocked by a concurrent verifier",
                                  lambda: retention_failed(ports))
                require(failed["lastFailureUnixSeconds"] >= failed["lastSuccessUnixSeconds"]
                        and failed["lastSuccessUnixSeconds"] > initial["lastSuccessUnixSeconds"]
                        and failed["retainedCount"] == 8 and all(bundle.is_dir() for bundle in previous),
                        "retention failure removed an old bundle or hid the published backup")

        with running_backup_probe(probe, root, env) as (process, ports, resume):
            restarted = status_at(ports)
            require(restarted["retainedCount"] == 8
                    and restarted["lastSuccessUnixSeconds"] == failed["lastSuccessUnixSeconds"]
                    and "lastFailure" not in restarted, "restart did not rebuild inventory")
            resume()
            wait_for(process, "rotation to seven completed bundles", lambda: (
                status_at(ports)["retainedCount"] == 7
            ))
            final = status_at(ports)
            browser, _ = log_in(ports["admin"], token)
            with closing(Socket(ports["admin"], browser)) as viewer:
                require(viewer.status == 101, "backup overview upgrade failed")
                viewer.until(lambda data: "backup" in data.get("storage", {}))
                require(viewer.data["storage"]["backup"] == final,
                        "HTTP and WebSocket backup snapshots differ")
        require(not previous[0].exists() and not previous[1].exists()
                and all(bundle.exists() for bundle in previous[2:])
                and not list(backups.glob("*.partial")), "rotation did not retire only the oldest entries")
        for bundle in backups.iterdir():
            run(rust, env, "--verify-backup", bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, help="optional Swift baseline CLI")
    parser.add_argument("--target-dir", type=Path, default=GATEWAY / "target")
    args = parser.parse_args()
    swift = args.swift.resolve(strict=True) if args.swift else None
    rust, probe = build(args.target_dir.resolve())
    with tempfile.TemporaryDirectory(prefix="codexone-online-backup-") as temporary:
        exercise(rust, swift, probe, Path(temporary).resolve() / "gateway")
        health_and_rotation(rust, probe, Path(temporary).resolve() / "health")
    print("PASS: SQLite backup during HTTP settlement, restart, pressure, failure, rotation and live status")


if __name__ == "__main__":
    main()
