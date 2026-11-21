#!/usr/bin/env python3
"""Verify v19 execution retention and manual release through the Rust gateway."""
import argparse
from contextlib import closing
from pathlib import Path
import sqlite3
import time

from compare import ProbeError
from verify_admin import document, login, request, running_admin
from verify_keys import call, create, shutdown
from verify_protocol import latest, start
from verify_snapshot_restore import request as generate

DAY = 86400
RELEASE = "/api/executions/unknown/release"


def wait_for_count(db, sql, expected):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if db.execute(sql).fetchone()[0] == expected:
            return
        time.sleep(0.025)
    raise ProbeError("Retention did not commit the expected batch")


def reopen(fixture, binary):
    fixture.process, fixture.ports = start(
        binary, fixture.config, fixture.root, admin_token_file=fixture.admin,
        business_day_offset="+08:00", admin_live=False,
    )
    return fixture.ports["admin"]


def verify(binary):
    with running_admin(binary, business_day_offset="+08:00", admin_live=False) as f:
        path = f.root / "state/core.sqlite"
        key, secret = create(f.ports["admin"])
        f.secrets.append(secret)
        status, _ = generate(f.ports["data"], secret)
        assert status == 200
        assert latest(path, "settled")["inputTokens"] == 5
        now = int(time.time())
        old = now // DAY * DAY - 91 * DAY - 2 * 3600
        old_day = old // DAY * DAY
        with closing(sqlite3.connect(path)) as db:
            shutdown(f.process, f.root, f.secrets)
            db.row_factory = sqlite3.Row
            source = dict(db.execute("SELECT * FROM attempts").fetchone())
            assert db.execute("SELECT COUNT(*) FROM bindings").fetchone()[0] == 2
            with db:
                db.execute("UPDATE attempts SET created_at_epoch=?", (old,))
                db.execute("UPDATE bindings SET expires_at_epoch=?", (now - 1,))
                db.execute(
                    "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES ('release_unknown','{}',?)",
                    (old,),
                )

            port = reopen(f, binary)
            wait_for_count(db, "SELECT COUNT(*) FROM attempts", 0)
            assert [
                db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                for table in ("attempts", "bindings", "maintenance_events", "usage_daily", "evidence")
            ] == [0, 0, 0, 1, 0]
            rollup = db.execute(
                "SELECT day_epoch,requests,input_tokens,cached_tokens,image_input_tokens FROM usage_daily"
            ).fetchone()
            assert tuple(rollup) == (old_day, 1, 5, 0, None)
            business_start = old_day - 8 * 3600
            status, daily = call(port, "GET", f"/api/usage/daily?days=1&end={business_start + DAY}")
            assert status == 200 and daily["businessDay"] == {"offsetMinutes": 480}
            bucket, = daily["buckets"]
            assert bucket["atUnixSeconds"] == business_start and bucket["requests"] == 1
            assert bucket["metrics"]["inputTokens"] == "5"
            status, keys = call(port, "GET", "/api/usage/keys")
            assert status == 200 and keys["keys"][0]["keyID"] == key["id"]
            assert keys["keys"][0]["lastUsedAtUnixSeconds"] == old

            shutdown(f.process, f.root, f.secrets)
            columns = ",".join(source)
            parameters = ",".join(":" + name for name in source)
            details = [
                dict(source, id=f"retire-{index:03}", request_id=None, created_at_epoch=old + index)
                for index in range(1, 102)
            ]
            details += [
                dict(source, id="bound", request_id=None, created_at_epoch=old - 1),
                dict(source, id="expired", request_id=None, created_at_epoch=now - DAY - 5,
                     state="unknown", unknown_since_epoch=now - DAY - 1, usage_json=None),
                dict(source, id="review", request_id=None, created_at_epoch=old - 2,
                     state="unknown", unknown_since_epoch=now, usage_json=None),
            ]
            with db:
                db.executemany(f"INSERT INTO attempts({columns}) VALUES ({parameters})", details)
                db.execute(
                    """UPDATE attempts SET admission_json=json_set(admission_json,'$.attempt',id),
                       output_rate_settled_at=NULL,output_rate=NULL"""
                )
                db.execute(
                    """INSERT INTO bindings SELECT principal,namespace,identity,'response','synthetic-bound',id,?
                       FROM attempts WHERE id='bound'""", (now + DAY,))
                db.executemany(
                    "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES ('release_unknown','{}',?)",
                    [(old,)] * 101,
                )
                db.execute(
                    "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES ('synthetic_other_action','{}',?)",
                    (old,),
                )
                db.executemany(
                    "INSERT INTO account_concurrency VALUES ('synthetic','i',?,1)",
                    [(now - DAY - index,) for index in range(1, 102)],
                )

            port = reopen(f, binary)
            wait_for_count(db, "SELECT SUM(requests) FROM usage_daily", 101)
            stale_samples = "SELECT COUNT(*) FROM account_concurrency WHERE at_epoch<?"
            assert db.execute(stale_samples, (now - DAY,)).fetchone()[0] == 1
            remaining = db.execute("SELECT id,state FROM attempts ORDER BY id")
            assert [tuple(row) for row in remaining] == [
                ("bound", "settled"), ("expired", "settled"), ("retire-101", "settled"), ("review", "unknown"),
            ]
            old_audits = "SELECT COUNT(*) FROM maintenance_events WHERE action='release_unknown' AND at_epoch=?"
            assert db.execute(old_audits, (old,)).fetchone()[0] == 1
            assert db.execute(
                "SELECT COUNT(*) FROM maintenance_events WHERE json_extract(record_json,'$.reason')='reconciliation_expired'"
            ).fetchone()[0] == 1

            snapshot = call(port, "GET", "/api/usage/headroom")[1]["unknownReconciliation"]
            assert snapshot["count"] == 1
            body = {"beforeUnixSeconds": snapshot["beforeUnixSeconds"], "expectedCount": snapshot["count"]}
            assert call(port, "POST", RELEASE, dict(body, beforeUnixSeconds=old - 2))[0] == 409
            assert call(port, "POST", RELEASE + "?unused=1", body)[0] == 400
            assert call(port, "POST", RELEASE, {"expectedCount": 1})[0] == 400
            assert call(port, "POST", RELEASE, dict(body, expectedCount=-1))[0] == 400
            assert call(port, "POST", RELEASE, dict(body, extra=True))[0] == 400
            assert call(port, "POST", RELEASE, dict(body, expectedCount=1.5))[0] == 400
            assert call(port, "POST", RELEASE, body, extra={"Content-Type": "text/plain"})[0] == 400
            assert call(port, "POST", RELEASE, body, extra={"Content-Encoding": "identity"})[0] == 400
            f.origin = f"http://127.0.0.1:{port}"
            assert document(request(port, "POST", RELEASE, body), 403)
            assert document(request(port, "POST", RELEASE, body, origin=f.origin), 401)
            cookie, csrf = login(f)
            assert document(request(port, "POST", RELEASE, body, cookie=cookie, origin=f.origin), 403)
            assert document(request(port, "POST", RELEASE, body, cookie=cookie, origin=f.origin, csrf=csrf)) == {"released": 1}
            assert call(port, "POST", RELEASE, body)[0] == 409
            manual = db.execute(
                "SELECT json_extract(record_json,'$.released') FROM maintenance_events WHERE json_extract(record_json,'$.reason')='manual'"
            ).fetchall()
            assert [tuple(row) for row in manual] == [(1,)]

            shutdown(f.process, f.root, f.secrets)
            port = reopen(f, binary)
            wait_for_count(db, "SELECT SUM(requests) FROM usage_daily", 103)
            assert db.execute("SELECT COUNT(*) FROM bindings").fetchone()[0] == 1
            assert db.execute(old_audits, (old,)).fetchone()[0] == 0
            assert db.execute(
                "SELECT COUNT(*) FROM maintenance_events WHERE action='synthetic_other_action' AND at_epoch=?", (old,)
            ).fetchone()[0] == 1
            assert db.execute("SELECT usage_unknown,input_tokens,estimated_micros FROM usage_daily WHERE usage_unknown=1").fetchone()[:] == (1, None, None)
            assert db.execute(stale_samples, (now - DAY,)).fetchone()[0] == 0
            assert document(request(port, "GET", "/api/usage/headroom", cookie=cookie), 401)
            assert call(port, "POST", RELEASE, {"beforeUnixSeconds": 0, "expectedCount": 0}) == (200, {"released": 0})
            assert call(port, "POST", RELEASE, body)[0] == 409
    print("PASS: Rust process retention, business-day and Key reports, bounded batches, release CAS/CSRF and restart")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=lambda raw: Path(raw).resolve())
    verify(parser.parse_args().binary)
