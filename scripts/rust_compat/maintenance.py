#!/usr/bin/env python3
"""Exercise the production maintenance CLIs against each other's synthetic data."""

import argparse
import contextlib
import hashlib
import json
import os
import select
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path


OLD = "a1" * 32
NEW = "b2" * 32
ADMIN = "synthetic-admin-for-maintenance-probe"
OLD_ID = hashlib.sha256(bytes.fromhex(OLD)).hexdigest()[:32]
NEW_ID = hashlib.sha256(bytes.fromhex(NEW)).hexdigest()[:32]


def private_file(path, value):
    with os.fdopen(
        os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
    ) as stream:
        stream.write(value)
    return path


def environment(directory, master, admin):
    env = {name: value for name, value in os.environ.items() if not name.startswith("CODEXONE_")}
    env.update(
        CODEXONE_DATA_DIRECTORY=str(directory),
        CODEXONE_ADMIN_TOKEN_FILE=str(admin),
        CODEXONE_ACCOUNT_MASTER_KEY_FILE=str(master),
        CODEXONE_BUSINESS_DAY_OFFSET="+08:00",
    )
    return env


def run(binary, env, *arguments, reject=False):
    result = subprocess.run(
        [binary, *arguments], env=env, text=True, capture_output=True, check=False, timeout=30
    )
    if reject:
        if result.returncode == 0:
            raise AssertionError(f"{arguments[0]} unexpectedly succeeded")
        return result.stderr
    if result.returncode != 0:
        raise AssertionError(f"{arguments[0]} failed with exit {result.returncode}\n{result.stderr}")
    return json.loads(result.stdout)


@contextlib.contextmanager
def probe(binary, env, *arguments):
    with subprocess.Popen(
        [binary, *arguments], env=env, text=True, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ) as process:
        def expect(message, command=None):
            if command is not None:
                process.stdin.write(command + "\n")
                process.stdin.flush()
            available, _, _ = select.select([process.stdout], [], [], 15)
            if not available or process.stdout.readline().strip() != message:
                raise AssertionError(f"probe did not report {message}")

        try:
            yield process, expect
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)


def store_query(path, sql):
    with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=rw", uri=True)) as db:
        db.execute("PRAGMA query_only=ON")
        return db.execute(sql).fetchall()


def restore_baseline(report, filename, requests=2, micros=3):
    return private_file(filename, json.dumps({
        "expectedRevision": 0,
        "restoreID": report["restore"]["id"],
        "auditReference": "synthetic-attestation",
        "missingUnresolvedRequests": requests,
        "missingUnresolvedMicros": micros,
        "freezeUntilUnixSeconds": report["minimumFreezeUntilUnixSeconds"],
    }))


def drill(args, root):
    swift, rust = args.swift, args.rust
    source_dir = root / "source"
    db = source_dir / "core.sqlite"
    admin = private_file(root / "admin", ADMIN)
    old = private_file(root / "old", OLD)
    new = private_file(root / "new", NEW)
    keyring = private_file(root / "keyring", json.dumps({
        "format": 1, "active": NEW, "decryptOnly": [OLD],
    }))
    old_env = environment(source_dir, old, admin)
    new_env = environment(source_dir, new, admin)
    ring_env = environment(source_dir, keyring, admin)
    probe_env = {**old_env, "CODEXONE_PROBE_KEY_FILE": str(old)}

    original_digest = hashlib.sha256(b"co1_synthetic-maintenance-key").hexdigest()
    manifest = private_file(root / "import.json", json.dumps({
        "version": 1, "capturedAtUnixSeconds": int(time.time()),
        "entries": [{
            "id": "synthetic-key", "principal": "synthetic-principal", "digest": original_digest,
            "policy": {"models": ["synthetic"], "limits": {"tokens": None, "active": None}},
            "sourceActive": True, "sourceExpiresAtUnixSeconds": None, "policyEquivalent": True,
        }],
    }))
    assert run(rust, old_env, "--import-keys", manifest) == {"importedKeys": 1, "enabledKeys": 0}
    run(swift, old_env, "--import-keys", manifest, reject=True)
    with contextlib.closing(sqlite3.connect(db)) as connection:
        connection.execute(
            "UPDATE managed_keys SET metadata_json=json_set(metadata_json,'$.enabled',json('true'))"
        )
        connection.commit()

    swift_bundle = root / "swift-bundle"
    rust_bundle = root / "rust-bundle"
    with probe(args.probe, probe_env, db) as (_, expect):
        expect("ready")
        expect("accounts_seeded", "account-seed-maintenance")
        expect("admitted", "admit")
        expect("bound", "bind")
        assert "locked" in run(rust, ring_env, "--backup", rust_bundle, reject=True)
        assert not rust_bundle.exists()
        expect("closed", "close")

    before = run(swift, old_env, "--backup", swift_bundle)
    assert run(rust, old_env, "--verify-backup", swift_bundle) == before
    assert before["requiredKeyIDs"] == [OLD_ID]
    assert run(rust, new_env, "--verify-backup", swift_bundle, reject=True)
    rust_manifest = run(rust, old_env, "--backup", rust_bundle)
    assert run(swift, old_env, "--verify-backup", rust_bundle) == rust_manifest
    assert rust_manifest["requiredKeyIDs"] == [OLD_ID]
    assert rust_manifest["sourceGeneration"] == before["sourceGeneration"]

    # Format 1 bundles can carry a prior schema. Build a v18 fixture by undoing
    # the single additive v19 migration on an isolated copy.
    older_bundle = root / "v18-bundle"
    shutil.copytree(swift_bundle, older_bundle)
    older_snapshot = older_bundle / "snapshot.sqlite"
    with contextlib.closing(sqlite3.connect(older_snapshot)) as connection:
        connection.execute("ALTER TABLE request_diagnostics DROP COLUMN reasoning_effort")
        connection.execute("PRAGMA user_version=18")
        connection.commit()
    older_manifest = {**before, "schema": 18}
    older_manifest["databaseBytes"] = older_snapshot.stat().st_size
    older_manifest["databaseSHA256"] = hashlib.sha256(older_snapshot.read_bytes()).hexdigest()
    (older_bundle / "manifest.json").write_text(json.dumps(older_manifest))
    assert run(swift, old_env, "--verify-backup", older_bundle) == older_manifest
    older_restore = root / "v18-restored-by-rust"
    report = run(rust, environment(older_restore, old, admin), "--restore", older_bundle)
    assert report["state"] == "restored_unreconciled"
    assert store_query(older_restore / "core.sqlite", "PRAGMA user_version") == [(19,)]

    damaged_bundle = root / "damaged-bundle"
    shutil.copytree(rust_bundle, damaged_bundle)
    with (damaged_bundle / "snapshot.sqlite").open("ab") as snapshot:
        snapshot.write(b"synthetic-damage")
    rejected_target = root / "rejected-restore"
    for backend in (swift, rust):
        run(backend, old_env, "--verify-backup", damaged_bundle, reject=True)
        run(backend, environment(rejected_target, old, admin), "--restore", damaged_bundle, reject=True)
        assert not rejected_target.exists()

    rust_restore = root / "restored-by-rust"
    swift_restore = root / "restored-by-swift"
    for restorer, reader, restore_dir, backup, source_manifest in (
        (rust, swift, rust_restore, swift_bundle, before),
        (swift, rust, swift_restore, rust_bundle, rust_manifest),
    ):
        restore_env = environment(restore_dir, old, admin)
        status = run(restorer, restore_env, "--restore", backup)
        assert status == run(reader, restore_env, "--maintenance-status")
        assert status["state"] == "restored_unreconciled"
        assert status["restore"]["backupID"] == source_manifest["id"]
        assert status["minimumFreezeUntilUnixSeconds"] % 86400 == 16 * 3600
        assert run(reader, old_env, "--verify-backup", backup) == source_manifest
        restored_db = restore_dir / "core.sqlite"
        generation = store_query(restored_db, "SELECT generation FROM maintenance_state")[0][0]
        assert generation != source_manifest["sourceGeneration"]
        assert store_query(restored_db, "SELECT state FROM attempts") == [("unknown",)]
        assert store_query(restored_db, "SELECT count(*) FROM bindings") == [(0,)]
        assert store_query(restored_db, "SELECT DISTINCT authorization FROM accounts") == [("requires_auth",)]
        digest, metadata = store_query(restored_db, "SELECT digest,metadata_json FROM managed_keys")[0]
        assert digest != original_digest
        metadata = json.loads(metadata)
        assert metadata["revision"] == 2 and not metadata["enabled"]

        run(reader, restore_env, "--backup", restore_dir.with_suffix(".denied"), reject=True)
        baseline = restore_baseline(status, restore_dir.with_suffix(".json"))
        frozen = run(reader, restore_env, "--reconcile-restored", baseline)
        assert frozen["state"] == "frozen"
        assert frozen == run(restorer, restore_env, "--reconcile-restored", baseline)
        assert frozen["missingUnresolvedRequests"] == 2 and frozen["missingUnresolvedMicros"] == 3
        assert store_query(restored_db, "SELECT COUNT(*) FROM maintenance_events") == [(2,)]
        run(restorer, restore_env, "--restore", backup, reject=True)

    nested_bundle = root / "nested-bundle"
    rust_restore_env = environment(rust_restore, old, admin)
    run(rust, rust_restore_env, "--backup", nested_bundle)
    inherited = run(swift, environment(root / "inherited", old, admin), "--restore", nested_bundle)
    assert inherited["missingUnresolvedRequests"] == 2 and inherited["missingUnresolvedMicros"] == 3
    assert inherited["state"] == "restored_unreconciled"

    # Rust writes the checkpoint and envelopes, Swift verifies both and the independent backup.
    rotate_rust = root / "rotate-rust"
    rotated = run(rust, ring_env, "--reencrypt-credentials", rotate_rust)
    assert rotated == run(swift, ring_env, "--key-status")
    assert rotated["requiredCurrentKeyIDs"] == [NEW_ID]
    assert rotated["checkpoint"]["rewritten"] == 20 and rotated["checkpoint"]["complete"]
    assert run(swift, old_env, "--verify-backup", rotate_rust)["requiredKeyIDs"] == [OLD_ID]

    # Swift writes a durable page, exits mid-job, and Rust resumes from that page.
    rotate_swift = root / "rotate-swift"
    reverse = private_file(root / "reverse", json.dumps({
        "format": 1, "active": OLD, "decryptOnly": [NEW],
    }))
    reverse_env = environment(source_dir, reverse, admin)
    with probe(args.probe, reverse_env, "--key-maintenance-probe", db, reverse, rotate_swift) as (process, expect):
        expect("page_committed:8")
        process.kill()
        process.wait(timeout=15)
    interrupted = run(rust, reverse_env, "--key-status")
    assert interrupted["checkpoint"]["rewritten"] == 8
    assert not interrupted["checkpoint"]["complete"]
    run(rust, reverse_env, "--backup", root / "during-reencryption", reject=True)
    assert "original target key" in run(rust, ring_env, "--resume-reencryption", reject=True)
    resumed = run(rust, reverse_env, "--resume-reencryption")
    assert resumed == run(swift, reverse_env, "--key-status")
    assert resumed["requiredCurrentKeyIDs"] == [OLD_ID]
    assert resumed["checkpoint"]["rewritten"] == 20 and resumed["checkpoint"]["complete"]

    raw = root / "synthetic-pre-upgrade.sqlite"
    shutil.copy2(older_snapshot, raw)
    inventory = private_file(root / "inventory.json", json.dumps({
        "format": 1, "inventoryComplete": True, "auditReference": "synthetic-inventory",
        "retainedBackups": [str(swift_bundle), str(rust_bundle)],
        "restoreDrills": [str(rust_restore), str(swift_restore)],
        "legacyDatabases": [str(raw)], "legacyRestoreAuditReference": "synthetic-legacy-audit",
    }))
    assert run(swift, old_env, "--check-key-retirement", inventory) == run(
        rust, old_env, "--check-key-retirement", inventory
    )
    print("Swift/Rust maintenance interoperability passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for binary in ("swift", "rust", "probe"):
        parser.add_argument("--" + binary, type=lambda value: Path(value).resolve(strict=True), required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        drill(args, Path(directory).resolve())


if __name__ == "__main__":
    main()
