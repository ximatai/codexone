#!/usr/bin/env python3
"""Business-day config/restart/restore via real binary, SQLite and loopback fake provider."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

from verify_admin import running_admin
from verify_keys import call, create
from verify_protocol import start, stop
from verify_snapshot_restore import request


def run(binary, root, *args, offset='UTC', ok=True):
    result = subprocess.run([binary, *map(str, args)], env={
        'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(root),
        'CODEXONE_BUSINESS_DAY_OFFSET': offset,
    }, capture_output=True, timeout=30)
    assert (result.returncode == 0) == ok, 'Synthetic business-day CLI failed: ' + result.stderr.decode(errors='replace')
    assert str(root).encode() not in result.stdout + result.stderr
    return json.loads(result.stdout) if ok else result


def verify(binary, previous_binary=None):
    for value in ['', 'utc', '+05:30', '+05:45', '+15:00', '-13:00', 'Asia/Shanghai', ' UTC']:
        result = subprocess.run([binary, '--check-config'], env={
            'PATH': os.defpath, 'CODEXONE_BUSINESS_DAY_OFFSET': value,
        }, capture_output=True, timeout=10)
        assert result.returncode == 78 and b'LISTENING' not in result.stdout
        assert result.stderr == b'Invalid business day offset configuration.\n'
    for value, minutes in [('UTC', 0), ('-12:00', -720), ('+14:00', 840), ('+00:00', 0)]:
        result = subprocess.run([binary, '--check-config'], env={
            'PATH': os.defpath, 'CODEXONE_BUSINESS_DAY_OFFSET': value,
        }, capture_output=True, timeout=10, check=True)
        assert json.loads(result.stdout)['businessDay'] == {'offsetMinutes': minutes}
    with running_admin(binary, business_day_offset='+08:00') as f:
        path = f.root / 'state/core.sqlite'
        key, secret = create(f.ports['admin'], limits={'tokens': 8, 'active': 2})
        f.secrets.append(secret)
        assert request(f.ports['data'], secret)[0] == 200
        deadline = time.monotonic() + 5
        while call(f.ports['admin'], 'GET', '/api/usage/keys')[1]['keys'][0]['tokens'] != '8':
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert request(f.ports['data'], secret)[0] == 429
        assert f.provider.calls == 1
        options = call(f.ports['admin'], 'GET', '/api/usage/options')[1]
        assert options['businessDay'] == {'offsetMinutes': 480} and options['timezone'] == 'UTC+08:00'
        summary = call(f.ports['admin'], 'GET', '/api/usage/keys')[1]
        start_at = summary['startUnixSeconds']
        assert (start_at + 8 * 3600) % 86400 == 0
        assert call(f.ports['admin'], 'GET', '/api/usage/daily?days=1&end=' + str(start_at + 86400))[0] == 200
        assert call(f.ports['admin'], 'GET', '/api/usage/daily?end=' + str(start_at + 1))[0] == 400
        stop(f.process)
        # Preserve a real admitted attempt, moving only its synthetic time into the
        # part of today's +08 day excluded by a selected replacement UTC day.
        now = int(time.time())
        utc_start = now // 86400 * 86400
        replacement = '+14:00' if start_at == utc_start - 8 * 3600 else '-12:00'
        replacement_seconds = 14 * 3600 if replacement == '+14:00' else -12 * 3600
        new_start = (now + replacement_seconds) // 86400 * 86400 - replacement_seconds
        # Seed a point in the old window outside the new one (either edge).
        old_point = start_at if start_at < new_start else new_start + 86400
        assert start_at <= old_point < start_at + 86400 and not new_start <= old_point < new_start + 86400
        with sqlite3.connect(path) as db:
            row = db.execute('SELECT id,admission_json FROM attempts').fetchone()
            admission = json.loads(row[1])
            assert admission['window'] == 'business-day-' + str(start_at)
            db.execute('UPDATE attempts SET created_at_epoch=?', (old_point,))
            assert db.execute('PRAGMA user_version').fetchone()[0] == 13
        f.process, f.ports = start(binary, f.config, f.root, admin_token_file=f.admin, business_day_offset=replacement)
        assert call(f.ports['admin'], 'GET', '/api/usage/keys')[1]['keys'][0]['tokens'] == '0'
        assert request(f.ports['data'], secret)[0] == 200
        stop(f.process)
        # Old UTC strings and new strings both decode; swapping the executable
        # back must leave history intact and count token usage by UTC timestamp.
        if previous_binary:
            f.process, f.ports = start(previous_binary, f.config, f.root, admin_token_file=f.admin)
            assert call(f.ports['admin'], 'GET', '/api/usage/keys')[0] == 200
            with sqlite3.connect(path) as db:
                assert db.execute("SELECT COUNT(*) FROM attempts WHERE window_id LIKE 'business-day-%'").fetchone()[0] == 2
            stop(f.process)
        bundle = f.root / 'synthetic.bundle'
        run(binary, f.root / 'state', '--backup', bundle)
        target = f.root / 'restore/core.sqlite'
        target.parent.mkdir(mode=0o700)
        record = run(binary, target.parent, '--restore', bundle, offset='+08:00')
        # CLI reports the same persisted UTC instant on future invocations.
        report = run(binary, target.parent, '--maintenance-status', offset='+08:00')
        restored_at = report['restore']['restoredUnixSeconds']
        expected = (restored_at + 8 * 3600) // 86400 * 86400 - 8 * 3600 + 86400
        assert report['minimumFreezeUntilUnixSeconds'] == expected
        baseline = f.root / 'baseline.json'
        baseline.write_text(json.dumps(dict(restoreID=report['restore']['id'], auditReference='synthetic-business-day', missingUnresolvedRequests=0, missingUnresolvedMicros=0, freezeUntilUnixSeconds=expected, expectedRevision=0)))
        baseline.chmod(0o600)
        run(binary, target.parent, '--reconcile-restored', baseline, offset='+08:00')
        assert run(binary, target.parent, '--maintenance-status', offset='UTC')['minimumFreezeUntilUnixSeconds'] == expected
        assert record['state'] == 'restored_unreconciled'
        if previous_binary:
            old_minimum = max(expected, (restored_at // 86400 + 1) * 86400)
            run(previous_binary, target.parent, '--maintenance-status', ok=expected >= old_minimum)
            if expected < old_minimum:
                print('CONFIRMED: previous binary rejects a reconciled restore with freeze before its UTC minimum')

    print('PASS: business-day real binary/fake provider configuration, restart, limits and restore')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--previous-binary')
    args = parser.parse_args()
    verify(str(Path(args.binary).resolve()), str(Path(args.previous_binary).resolve()) if args.previous_binary else None)
