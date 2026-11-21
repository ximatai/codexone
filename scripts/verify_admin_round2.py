#!/usr/bin/env python3
"""Round-two backend HTTP and real previous-binary migration checks; synthetic loopback only."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from verify_admin import document, request
from verify_managed_fixture import AUTH, authorize, listening, oauth_provider, prepare, start_gateway
from verify_process import environment, release
from verify_protocol import current_schema_version


def port_line(process, pattern):
    port, _ = listening(process, pattern)
    return port


def verify_accounts(probe, binary, *, rust=False):
    schema = current_schema_version(binary)
    with oauth_provider(rust=rust) as server:
        with tempfile.TemporaryDirectory(prefix='codexone-round2-') as directory:
            root = Path(directory)
            database = prepare(root)
            web = root / 'web'
            (web / 'assets').mkdir(parents=True)
            (web / 'index.html').write_text('<!doctype html><html><head><script type="module" src="/assets/entry.js"></script></head><body>synthetic</body></html>')
            (web / 'assets/entry.js').write_text('window.synthetic=true;')
            def start():
                process, port, _ = start_gateway(probe, root, server, rust=rust, web=web)
                return process, port
            process, port = start()
            auth = AUTH
            try:
                account = authorize(port, server)
                assert account['accessExpiresAtUnixSeconds'] > int(time.time())
                assert isinstance(account['credentialUpdatedAtUnixSeconds'], int)
                for secret in server.issued:
                    assert secret not in json.dumps(account)
                assert not any(field in account for field in ('accessToken', 'refreshToken', 'idToken', 'envelope', 'namespace', 'refreshIntent'))
                updated = account['credentialUpdatedAtUnixSeconds']
                expires = account['accessExpiresAtUnixSeconds']
                path = '/api/accounts/' + account['id'] + '/display-name'
                body = {'revision': account['revision'], 'displayName': '合成账号'}
                assert request(port, 'PUT', path, body)[0] == 403
                for invalid in ('', 'x' * 65, 'line\nbreak', '\u202esecret', 17):
                    assert request(port, 'PUT', path, dict(body, displayName=invalid), **auth)[0] == 400
                assert request(port, 'PUT', path + '?extra=1', body, **auth)[0] == 400
                named = document(request(port, 'PUT', path, body, **auth))['account']
                assert named['displayName'] == '合成账号' and named['credentialVersion'] == account['credentialVersion']
                assert request(port, 'PUT', path, body, **auth)[0] == 409
                account = document(request(port, 'PUT', '/api/accounts/' + account['id'], {'revision': named['revision'], 'mode': 'enabled'}, **auth))['account']
                assert account['displayName'] == named['displayName']
                candidates_path = '/api/accounts/' + account['id'] + '/model-candidates'
                with server.guard:
                    server.control['model_discovery_delay'] = 6
                discovered = document(request(port, 'POST', candidates_path, **auth))
                assert [(item['id'], item['state']) for item in discovered['candidates']] == [
                    ('synthetic-nova', 'candidate'), ('synthetic-incomplete', 'incomplete')]
                with server.guard:
                    server.control.pop('model_discovery_delay')
                    server.control['model_discovery_failure'] = True
                assert request(port, 'POST', candidates_path, **auth)[0] == 503
                assert document(request(port, 'GET', '/api/models', **auth))['candidates'] == discovered['candidates']
                body = dict(revision=discovered['revision'], model='synthetic-nova', enabled=True,
                            candidateRevision=discovered['candidateRevision'],
                            inputMicrosPerMillion=0, outputMicrosPerMillion=0)
                assert request(port, 'PUT', '/api/models', dict(body, model='synthetic-incomplete'), **auth)[0] == 400
                with server.guard:
                    server.control['model_discovery_failure'] = False
                newer = document(request(port, 'POST', candidates_path, **auth))
                assert newer['candidateRevision'] != body['candidateRevision']
                assert request(port, 'PUT', '/api/models', body, **auth)[0] == 409
                body['candidateRevision'] = newer['candidateRevision']
                assert request(port, 'PUT', '/api/models',
                    dict(body, allowedReasoningEfforts=['low'], defaultReasoningEffort='low'), **auth)[0] == 400
                activated = document(request(port, 'PUT', '/api/models',
                    dict(body, allowedReasoningEfforts=None, defaultReasoningEffort='high'), **auth))
                assert activated['active'][1]['configuredDefaultReasoningEffort'] == 'high'
                assert request(port, 'PUT', '/api/models', body, **auth)[0] == 409
                key_options = document(request(port, 'GET', '/api/keys/options', **auth))
                assert key_options['models'] == ['synthetic-text', 'synthetic-nova']
                assert key_options['reasoningEfforts']['synthetic-nova'] == ['high']
                settings_path = '/api/models/reasoning'
                settings = dict(revision=key_options['catalogRevision'], model='synthetic-nova',
                                allowedReasoningEfforts=None, defaultReasoningEffort='high')
                assert request(port, 'PUT', settings_path, settings)[0] == 403
                assert request(port, 'PUT', settings_path, dict(settings, defaultReasoningEffort='low'), **auth)[0] == 400
                saved = document(request(port, 'PUT', settings_path, settings, **auth))
                assert saved['active'][1]['configuredDefaultReasoningEffort'] == 'high'
                assert request(port, 'PUT', settings_path, settings, **auth)[0] == 409
            finally:
                release(process)
            with sqlite3.connect(database) as db:
                db.executescript("""
                    ALTER TABLE request_diagnostics DROP COLUMN reasoning_effort;
                    ALTER TABLE model_directory_routes DROP COLUMN reasoning_efforts;
                    UPDATE model_directory SET document=json_remove(document,'$.active[1].reasoningSettings');
                    PRAGMA user_version=17;
                """)
            process, port = start()
            try:
                account = document(request(port, 'GET', '/api/accounts', **auth))['accounts'][0]
                assert account['displayName'] == '合成账号'
                persisted = document(request(port, 'GET', '/api/models', **auth))
                assert [item['id'] for item in persisted['active']] == ['synthetic-text', 'synthetic-nova']
                assert persisted['candidates'] == []
                assert persisted['active'][1]['configuredDefaultReasoningEffort'] is None
                with sqlite3.connect(database) as db:
                    assert db.execute('PRAGMA user_version').fetchone()[0] == schema
                    assert db.execute("SELECT reasoning_efforts FROM model_directory_routes WHERE model='synthetic-nova'").fetchone() == (None,)
                backup, = database.parent.glob('core.sqlite.pre-v18-*.sqlite')
                with sqlite3.connect(backup) as db:
                    assert db.execute('PRAGMA user_version').fetchone()[0] == 17
                settings['revision'] = persisted['revision']
                persisted = document(request(port, 'PUT', settings_path, settings, **auth))
                retired = document(request(port, 'PUT', '/api/models',
                                           dict(revision=persisted['revision'], model='synthetic-nova', enabled=False), **auth))
                assert [item['id'] for item in retired['retired']] == ['synthetic-nova']
                assert document(request(port, 'GET', '/api/keys/options', **auth))['models'] == ['synthetic-text']
                enable = dict(revision=retired['revision'], model='synthetic-nova', enabled=True)
                assert request(port, 'PUT', '/api/models', enable, **auth)[0] == 409
                with server.guard:
                    server.control['model_discovery_failure'] = False
                    server.control['model_changed'] = True
                refreshed = document(request(port, 'POST', '/api/accounts/' + account['id'] + '/model-candidates', **auth))
                assert refreshed['retired'][0]['visionInput'] is True
                assert refreshed['retired'][0]['previousVisionInput'] is False
                enable['candidateRevision'] = refreshed['candidateRevision']
                assert request(port, 'PUT', '/api/models',
                    dict(enable, allowedReasoningEfforts=['high'], defaultReasoningEffort='low'), **auth)[0] == 400
                restored = document(request(port, 'PUT', '/api/models',
                    dict(enable, allowedReasoningEfforts=['high'], defaultReasoningEffort='high'), **auth))
                assert [item['id'] for item in restored['active']] == ['synthetic-text', 'synthetic-nova']
                assert restored['active'][1]['reasoningEfforts'] == ['high']
                assert restored['active'][1]['configuredDefaultReasoningEffort'] == 'high'
                retired_again = document(request(port, 'PUT', '/api/models',
                    dict(model='synthetic-nova', enabled=False, revision=restored['revision']), **auth))
                with server.guard:
                    server.control['model_changed'] = False
                refreshed = document(request(port, 'POST', candidates_path, **auth))
                assert refreshed['retired'][0]['configuredReasoningEfforts'] == ['high']
                reenabled = document(request(port, 'PUT', '/api/models',
                    dict(enable, revision=retired_again['revision'], candidateRevision=refreshed['candidateRevision'],
                         allowedReasoningEfforts=['high'], defaultReasoningEffort=None), **auth))
                assert reenabled['active'][1]['configuredReasoningEfforts'] == ['high']
                assert restored['active'][1]['visionInput'] is True
                assert account['credentialUpdatedAtUnixSeconds'] == updated
                assert account['accessExpiresAtUnixSeconds'] == expires
                account = document(request(port, 'PUT', path, {'revision': account['revision'], 'displayName': None}, **auth))['account']
                assert account['displayName'] is None
            finally:
                release(process)
            # Missing historical audit evidence must remain null, never use mode/name time.
            with sqlite3.connect(database) as db:
                db.execute("DELETE FROM account_events WHERE action IN ('create_verified','reauthorize_verified','refresh_commit')")
            process, port = start()
            try:
                account = document(request(port, 'GET', '/api/accounts', **auth))['accounts'][0]
                assert account['credentialUpdatedAtUnixSeconds'] is None
                assert account['accessExpiresAtUnixSeconds'] == expires
            finally:
                release(process)
            assert server.calls == 1
            print('PASS: account and model-directory HTTP, CAS, failed discovery retention, persisted activation and retirement')


def verify_previous(binary, previous):
    with tempfile.TemporaryDirectory(prefix='codexone-v11-upgrade-') as directory:
        root = Path(directory)
        state = root / 'state'
        env = environment(CODEXONE_DATA_DIRECTORY=str(state))
        process = subprocess.Popen([previous], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            port_line(process, rb'LISTENING data 127\.0\.0\.1:(\d+)')
        finally:
            release(process)
        database = state / 'core.sqlite'
        with sqlite3.connect(database) as db:
            previous_version = db.execute('PRAGMA user_version').fetchone()[0]
            assert previous_version in (8,9,10)
        before = hashlib.sha256(database.read_bytes()).digest()
        refused = subprocess.run([binary], env=env, capture_output=True, timeout=10)
        assert refused.returncode != 0 and hashlib.sha256(database.read_bytes()).digest() == before
        migrated = subprocess.run([binary, '--migrate'], env=env, capture_output=True, timeout=10)
        assert migrated.returncode == 0
        backups = list(state.glob('core.sqlite.pre-v13-*.sqlite'))
        assert len(backups) == 1 and backups[0].stat().st_mode & 0o777 == 0o600
        with sqlite3.connect(backups[0]) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == previous_version
        process = subprocess.Popen([binary], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            port_line(process, rb'LISTENING data 127\.0\.0\.1:(\d+)')
        finally:
            release(process)
        with sqlite3.connect(database) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == current_schema_version(binary)
            assert 'display_name' in [row[1] for row in db.execute('PRAGMA table_info(accounts)')]
        before = hashlib.sha256(database.read_bytes()).digest()
        refused = subprocess.run([previous], env=env, capture_output=True, timeout=10)
        assert refused.returncode != 0 and hashlib.sha256(database.read_bytes()).digest() == before
        assert not list(state.glob('*.partial'))
        print(f'PASS: actual v{previous_version} binary startup control; v11 refuses unmigrated v{previous_version}; offline backup migration; v{previous_version} refuses v11 without database changes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    probes = parser.add_mutually_exclusive_group(required=True)
    probes.add_argument('--probe', type=Path)
    probes.add_argument('--rust-probe', type=Path)
    parser.add_argument('--previous-binary', type=Path)
    args = parser.parse_args()
    verify_accounts(str((args.rust_probe or args.probe).resolve()), str(args.binary.resolve()), rust=args.rust_probe is not None)
    if args.previous_binary:
        verify_previous(str(args.binary.resolve()), str(args.previous_binary.resolve()))
