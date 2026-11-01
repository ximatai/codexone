#!/usr/bin/env python3
"""Offline CLI/real SQLite/process recovery checks with only private synthetic state."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time

from verify_admin import running_admin
from verify_keys import create
from verify_protocol import start, stop, latest


def command(binary, directory, *arguments, ok=True):
    result = subprocess.run([binary, *map(str, arguments)],
        env={'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(directory)}, capture_output=True, timeout=30)
    assert len(result.stdout + result.stderr) < 32768
    assert str(directory).encode() not in result.stdout + result.stderr
    assert (result.returncode == 0) == ok, 'Snapshot command failed; private diagnostics withheld'
    return json.loads(result.stdout) if ok else result


def request(port, secret, *, stream=False, prompt='synthetic'):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        client.request('POST', '/v1/responses', body=json.dumps({'model': 'synthetic-text', 'input': prompt, 'stream': stream}),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + secret})
        response = client.getresponse()
        return response.status, response.read()
    finally: client.close()


def ready(port):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        client.request('GET', '/health/ready');response = client.getresponse();response.read();return response.status
    finally:client.close()


def stopped(process):
    if process.poll() is None:process.terminate()
    try:
        process.wait(timeout=10)
        assert process.returncode == 0
        logs = process.stdout.read(131073)
        assert len(logs) < 131072
    finally:stop(process)


def killed_restore(binary, bundle, directory):
    process = subprocess.Popen([binary, '--restore', str(bundle)],
        env={'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(directory)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 15
        while not (directory / 'core.sqlite.restore-pending').exists():
            assert process.poll() is None, 'Restore completed before fault injection barrier'
            assert time.monotonic() < deadline
            time.sleep(0.001)
        process.kill();process.wait(timeout=5)
        assert process.returncode != 0
    finally:
        if process.poll() is None:process.kill();process.wait(timeout=5)
        process.stdout.close();process.stderr.close()
    # Ordinary startup must not initialize an empty ready DB or admit from a partial copy.
    refused = command(binary, directory, '--maintenance-status', ok=False)
    assert b'Incomplete restore target' in refused.stderr
    assert not (directory / 'core.sqlite').exists()


def main():
    parser = argparse.ArgumentParser(description=__doc__);parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args();binary = str(args.binary.resolve())
    with running_admin(binary) as f:
        key, secret = create(f.ports['admin'], principal='synthetic-restore')
        assert request(f.ports['data'], secret)[0] == 200
        assert request(f.ports['data'], secret, stream=True, prompt='abrupt')[0] == 200
        latest(f.root / 'state/core.sqlite', 'unknown')
        command(binary, f.root / 'state', '--backup', f.root / 'online-refused', ok=False)
        assert not (f.root / 'online-refused').exists()
        stopped(f.process);f.process = None
        bundle = f.root / 'bundle'
        manifest = command(binary, f.root / 'state', '--backup', bundle)
        assert manifest['schema'] == 11 and len(manifest['databaseSHA256']) == 64
        assert hashlib.sha256((bundle / 'snapshot.sqlite').read_bytes()).hexdigest() == manifest['databaseSHA256']
        assert bundle.stat().st_mode & 511 == 448
        for path in bundle.iterdir():assert path.stat().st_mode & 511 == 384
        command(binary, f.root / 'state', '--backup', bundle, ok=False)
        # Continue the original service after backup; this execution will be absent from the old snapshot.
        f.process, f.ports = start(binary, f.config, f.root, admin_token_file=f.admin, web_directory=f.web_directory)
        assert request(f.ports['data'], secret)[0] == 200
        stopped(f.process);f.process = None
        with sqlite3.connect(f.root / 'state/core.sqlite') as db:
            original_count = db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
        parent = f.root / 'restored';parent.mkdir(mode=0o700)
        state = parent / 'state'
        report = command(binary, state, '--restore', bundle)
        assert report['state'] == 'restored_unreconciled'
        record = report['restore']
        assert record['snapshotUnixSeconds'] <= record['restoredUnixSeconds']
        assert record['backupID'] == manifest['id']
        assert command(binary, state, '--maintenance-status')['state'] == 'restored_unreconciled'
        command(binary, state, '--restore', bundle, ok=False)
        with sqlite3.connect(state / 'core.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == original_count - 1
            assert db.execute("SELECT COUNT(*) FROM attempts WHERE state='unknown'").fetchone()[0] == 1
            assert not db.execute('SELECT * FROM bindings').fetchall()
            assert not json.loads(db.execute('SELECT metadata_json FROM managed_keys').fetchone()[0])['enabled']
            assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
        # A restored legacy static identity must fail before listeners, rather than claim readiness.
        legacy = f.root / 'legacy.json'
        legacy.write_text(json.dumps({**json.loads(f.config.read_text()), 'managedKeys': False,
            'principal': 'synthetic-legacy', 'keyID': 'synthetic-legacy',
            'keySHA256': hashlib.sha256(b'synthetic-legacy-secret').hexdigest()}))
        legacy.chmod(0o600)
        refused = subprocess.run([binary], env={'PATH': os.defpath,
            'CODEXONE_DATA_DIRECTORY': str(state), 'CODEXONE_IDENTITY_CONFIG': str(legacy),
            'CODEXONE_ADMIN_TOKEN_FILE': str(f.admin)}, capture_output=True, timeout=10)
        assert refused.returncode != 0 and b'LISTENING' not in refused.stdout
        assert b'Restored databases require managed Keys' in refused.stderr
        process, ports = start(binary, f.config, parent, admin_token_file=f.admin, web_directory=f.web_directory)
        try:
            assert ready(ports['admin']) == 503 and request(ports['data'], secret)[0] == 401
            _, fresh_secret = create(ports['admin'], principal='synthetic-new-window')
            before = f.provider.calls
            status, body = request(ports['data'], fresh_secret)
            assert status == 503 and b'maintenance_required' in body and f.provider.calls == before
            command(binary, state, '--reconcile-restored', f.root / 'absent-baseline.json', ok=False)
        finally:stopped(process)
        baseline = {'expectedRevision': 0, 'restoreID': record['id'], 'auditReference': 'synthetic-external-audit-1',
            'missingUnresolvedRequests': 1, 'missingUnresolvedMicros': 10,
            'freezeUntilUnixSeconds': report['minimumFreezeUntilUnixSeconds']}
        baseline_file = f.root / 'baseline.json'
        for changed in ({'restoreID': '00000000-0000-0000-0000-000000000000'},
                        {'freezeUntilUnixSeconds': record['restoredUnixSeconds']},
                        {'missingUnresolvedMicros': -1}):
            baseline_file.write_text(json.dumps({**baseline, **changed}));baseline_file.chmod(0o600)
            command(binary, state, '--reconcile-restored', baseline_file, ok=False)
        baseline_file.write_text(json.dumps(baseline))
        reconciled = command(binary, state, '--reconcile-restored', baseline_file)
        assert reconciled['state'] == 'frozen' and reconciled['restore']['baseline'] == baseline
        assert command(binary, state, '--reconcile-restored', baseline_file) == reconciled
        process, ports = start(binary, f.config, parent, admin_token_file=f.admin, web_directory=f.web_directory)
        try:assert ready(ports['admin']) == 503 and request(ports['data'], fresh_secret)[0] == 503
        finally:stopped(process)
        # Advance the persisted synthetic time fixture; there is no runtime clock override.
        now = int(time.time())
        with sqlite3.connect(state / 'core.sqlite') as db:
            db.execute("UPDATE maintenance_state SET restore_json=json_set(restore_json,'$.snapshotUnixSeconds',?,'$.restoredUnixSeconds',?,'$.baseline.freezeUntilUnixSeconds',?)", (now-172800, now-86400, now//86400*86400))
        process, ports = start(binary, f.config, parent, admin_token_file=f.admin, web_directory=f.web_directory)
        try:
            assert ready(ports['admin']) == 200 and request(ports['data'], fresh_secret)[0] == 200
            assert request(ports['data'], secret)[0] == 401
        finally:stopped(process)
        print('PASS: real CLI backup/restore/status/audit, lost interval, old Key invalidation, maintenance restart, frozen windows and new-window generation')
        # A backup can be mounted read-only: restore must not create source files.
        for path in bundle.iterdir():path.chmod(0o400)
        bundle.chmod(0o500)
        readonly = command(binary, f.root / 'readonly-restored', '--restore', bundle)
        assert readonly['state'] == 'restored_unreconciled'
        bundle.chmod(0o700)
        for path in bundle.iterdir():path.chmod(0o600)
        # Completed snapshots are independent: missing manifest, changed bytes, symlink and broad modes fail before target publication.
        for label in ('incomplete', 'corrupt', 'symlink', 'broad'):
            bad = f.root / label;shutil.copytree(bundle,bad)
            if label == 'incomplete':(bad / 'manifest.json').unlink()
            elif label == 'corrupt':
                with (bad / 'snapshot.sqlite').open('ab') as file:file.write(b'synthetic-corruption')
            elif label == 'symlink':
                (bad / 'snapshot.sqlite').unlink();(bad / 'snapshot.sqlite').symlink_to(bundle / 'snapshot.sqlite')
            else:(bad / 'manifest.json').chmod(0o644)
            command(binary, f.root / ('refused-' + label), '--restore', bad, ok=False)
            assert not (f.root / ('refused-' + label)).exists()
        # Grow only synthetic SQLite pages to make an actual interrupted copy observable.
        with sqlite3.connect(f.root / 'state/core.sqlite') as db:
            db.execute('CREATE TABLE synthetic_fault_pages(payload BLOB)')
            db.execute('INSERT INTO synthetic_fault_pages VALUES(zeroblob(33554432))')
        large = f.root / 'large'
        command(binary, f.root / 'state', '--backup', large)
        killed_restore(binary, large, f.root / 'killed-target')
        assert hashlib.sha256((large / 'snapshot.sqlite').read_bytes()).hexdigest() == json.loads((large / 'manifest.json').read_text())['databaseSHA256']
        print('PASS: private completed-bundle integrity/modes/symlink/refusal and actual SIGKILL restore barrier; original backup remains intact')

if __name__ == '__main__':main()
