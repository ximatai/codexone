#!/usr/bin/env python3
"""Round-two backend HTTP and real previous-binary migration checks; synthetic loopback only."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import sqlite3
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit
from verify_account_admin_ui import SyntheticOAuth, ADMIN
from verify_admin import document, request
from verify_process import environment, release
from verify_protocol import current_schema_version


def port_line(process, pattern):
    output = b''
    deadline = time.monotonic() + 15
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            assert process.poll() is None, 'Synthetic assembly exited before listening '
            if selector.select(.1):
                output += os.read(process.stdout.fileno(), 4096)
                assert len(output) <= 65536
                match = re.search(pattern, output)
                if match:
                    return int(match[1])
    raise AssertionError('Synthetic assembly did not listen within budget')


def verify_accounts(probe):
    server = ThreadingHTTPServer(('127.0.0.1', 0), SyntheticOAuth)
    server.daemon_threads = True
    server.guard = threading.Lock()
    server.control = {}
    server.calls = server.quota_calls = 0
    server.issued = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-round2-') as directory:
            root = Path(directory)
            for name, value in [('admin', ADMIN), ('master', '6b' * 32)]:
                (root / name).write_text(value)
                (root / name).chmod(0o600)
            web = root / 'web'
            (web / 'assets').mkdir(parents=True)
            (web / 'index.html').write_text('<!doctype html><html><head><script type="module" src="/assets/entry.js"></script></head><body>synthetic</body></html>')
            (web / 'assets/entry.js').write_text('window.synthetic=true;')
            def start():
                process = subprocess.Popen([probe, '--account-admin-ui', str(root), str(web), str(server.server_port)],
                    env={'PATH': os.defpath}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                try:
                    return process, port_line(process, rb'ADMIN_PORT (\d+)')
                except BaseException:
                    release(process)
                    raise
            process, port = start()
            auth = {'headers': {'Authorization': 'Bearer ' + ADMIN}}
            try:
                flow = document(request(port, 'POST', '/api/accounts/authorization', {'target': None, 'method': 'callback'}, **auth))
                query = parse_qs(urlsplit(flow['authorizationURL']).query)
                with server.guard:
                    server.control.update(challenge=query['code_challenge'][0], nonce=query['nonce'][0])
                callback = 'http://localhost:1455/auth/callback?' + urlencode({'state': query['state'][0], 'code': 'synthetic-code+/='})
                account = document(request(port, 'POST', '/api/accounts/authorization/' + flow['flowID'], {'callbackURL': callback}, **auth))['account']
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
                assert request(port, 'PUT', '/api/models', body, **auth)[0] == 200
                assert request(port, 'PUT', '/api/models', body, **auth)[0] == 409
                key_options = document(request(port, 'GET', '/api/keys/options', **auth))
                assert key_options['models'] == ['synthetic-text', 'synthetic-nova']
                assert key_options['reasoningEfforts']['synthetic-nova'] == ['high']
            finally:
                release(process)
            process, port = start()
            try:
                account = document(request(port, 'GET', '/api/accounts', **auth))['accounts'][0]
                assert account['displayName'] == '合成账号'
                persisted = document(request(port, 'GET', '/api/models', **auth))
                assert [item['id'] for item in persisted['active']] == ['synthetic-text', 'synthetic-nova']
                assert persisted['candidates'] == []
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
                restored = document(request(port, 'PUT', '/api/models', enable, **auth))
                assert [item['id'] for item in restored['active']] == ['synthetic-text', 'synthetic-nova']
                assert restored['active'][1]['reasoningEfforts'] == ['low', 'high']
                assert restored['active'][1]['visionInput'] is True
                assert account['credentialUpdatedAtUnixSeconds'] == updated
                assert account['accessExpiresAtUnixSeconds'] == expires
                account = document(request(port, 'PUT', path, {'revision': account['revision'], 'displayName': None}, **auth))['account']
                assert account['displayName'] is None
            finally:
                release(process)
            # Missing historical audit evidence must remain null, never use mode/name time.
            database = next(root.rglob('core.sqlite'))
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
    finally:
        server.shutdown()
        server.server_close()


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
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--previous-binary', type=Path)
    args = parser.parse_args()
    verify_accounts(str(args.probe.resolve()))
    if args.previous_binary:
        verify_previous(str(args.binary.resolve()), str(args.previous_binary.resolve()))
