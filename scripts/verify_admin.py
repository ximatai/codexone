#!/usr/bin/env python3
"""Browser management API and public asset boundaries on real loopback sockets; no accounts."""
import argparse
from contextlib import contextmanager
import http.client
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
from types import SimpleNamespace
from verify_protocol import Upstream, start, latest
from verify_keys import ADMIN, LIMITS, shutdown


def request(port, method, path, body=None, *, cookie=None, origin=None, csrf=None, headers=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=12)
    fields = {'Content-Type': 'application/json'}
    if cookie:
        fields['Cookie'] = cookie
    if origin:
        fields['Origin'] = origin
    if csrf:
        fields['X-CodexOne-CSRF'] = csrf
    fields.update(headers or {})
    connection.request(method, path, json.dumps(body) if body is not None else None, fields)
    response = connection.getresponse()
    result = response.status, dict(response.getheaders()), response.read()
    connection.close()
    return result


def document(result, status=200):
    assert result[0] == status
    assert result[1]['cache-control'] == 'no-store'
    return json.loads(result[2])


def login(fixture, *, cookie=None, origin=None):
    result = request(fixture.ports['admin'], 'POST', '/api/session', {'secret': ADMIN}, cookie=cookie,
                     origin=origin or fixture.origin)
    payload = document(result)
    raw = result[1]['set-cookie']
    parsed = SimpleCookie(raw)
    name = '__Host-codexone_admin'
    assert parsed[name]['httponly'] and parsed[name]['secure']
    assert parsed[name]['samesite'] == 'Strict' and parsed[name]['path'] == '/' and not parsed[name]['domain']
    assert parsed[name]['max-age'] == '1800'
    token = parsed[name].value
    csrf = payload['csrf']
    assert len(token) == 47 and len(csrf) == 47 and token.encode() not in result[2] and ADMIN.encode() not in result[2]
    fixture.secrets.extend([token, csrf])
    return name + '=' + token, csrf


@contextmanager
def running_admin(binary, web_directory=None, account_master=False):
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
    provider.daemon_threads = True
    provider.calls = 0
    provider.guard = threading.Lock()
    provider.cancelled = threading.Event()
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-admin-') as temporary:
            root = Path(temporary)
            admin = root / 'admin'
            admin.write_text(ADMIN)
            admin.chmod(0o600)
            if web_directory is None:
                web_directory = root / 'web'
                (web_directory / 'assets').mkdir(parents=True)
                (web_directory / 'index.html').write_text('<!doctype html><html><head><title>Synthetic Admin</title><script type="module" src="/assets/entry.js"></script></head><body>synthetic web bundle</body></html>')
                (web_directory / 'assets/entry.js').write_text('window.syntheticAsset = true;')
                (web_directory / 'assets/entry.css').write_text('body { color: black; }')
            master = root / 'master'
            if account_master:
                master.write_text('5a' * 32)
                master.chmod(0o600)
            config = root / 'config.json'
            config.write_text(json.dumps(dict(managedKeys=True, namespace='synthetic', identity='i', reservedMicros=1,
                models=[dict(id=model, inputMicrosPerMillion=0, outputMicrosPerMillion=0,
                             catalog=dict(baseInstructions='Explicit synthetic fixture guidance'))
                        for model in ['synthetic-text', 'synthetic-other']],
                upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1')))
            config.chmod(0o600)
            process, ports = start(binary, config, root, admin_token_file=admin, web_directory=web_directory,
                                   account_master_key_file=master if account_master else None)
            fixture = SimpleNamespace(root=root, process=process, ports=ports, provider=provider, admin=admin,
                                      config=config, web_directory=web_directory, secrets=[master.read_text()] if account_master else [],
                                      origin=f'http://127.0.0.1:{ports["admin"]}')
            try:
                yield fixture
            finally:
                if fixture.process is not None and not fixture.process.stdout.closed:
                    shutdown(fixture.process, root, fixture.secrets)
    finally:
        provider.shutdown()
        provider.server_close()


def verify(binary):
    with running_admin(binary) as f:
        port = f.ports['admin']
        assert request(port, 'GET', '/api/session')[0] == 401
        assert request(port, 'POST', '/api/session', {'secret': ADMIN})[0] == 403
        assert request(port, 'POST', '/api/session', {'secret': 'synthetic-wrong-admin'}, origin=f.origin)[0] == 401
        assert request(port, 'POST', '/api/session', {'secret': ADMIN}, origin=f.origin, headers={'Host': 'foreign.example'})[0] == 403
        cookie, csrf = login(f)
        assert document(request(port, 'GET', '/api/session', cookie=cookie))['csrf'] == csrf
        assert document(request(port, 'GET', '/api/keys/options', cookie=cookie))['models'] == ['synthetic-text', 'synthetic-other']
        create = dict(principal='browser-synthetic', models=['synthetic-text'], limits=LIMITS)
        assert request(port, 'POST', '/api/keys', create, cookie=cookie, origin=f.origin)[0] == 403
        assert request(port, 'POST', '/api/keys', create, cookie=cookie, origin='https://foreign.example', csrf=csrf)[0] == 403
        assert request(port, 'POST', '/api/keys', create, cookie=cookie, csrf=csrf)[0] == 403
        assert request(port, 'GET', '/api/keys', cookie=cookie, headers={'Authorization': 'Bearer ' + ADMIN})[0] == 403
        assert request(port, 'GET', '/api/keys', cookie=cookie, headers={'Sec-Fetch-Site': 'cross-site'})[0] == 403
        created = document(request(port, 'POST', '/api/keys', create, cookie=cookie, origin=f.origin, csrf=csrf), 201)
        key, secret = created['key'], created['secret']
        f.secrets.append(secret)
        listing = document(request(port, 'GET', '/api/keys', cookie=cookie))
        assert len(listing['keys']) == 1 and 'secret' not in json.dumps(listing) and 'digest' not in json.dumps(listing)
        result = request(f.ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'synthetic', 'stream': False}, headers={'Authorization': 'Bearer ' + secret})
        assert result[0] == 200
        latest(f.root / 'state/core.sqlite', 'settled')
        # Disabled credentials can be rotated without briefly enabling the old secret.
        update = dict(revision=key['revision'], enabled=False, models=key['models'], limits=key['limits'])
        disabled = document(request(port, 'PUT', '/api/keys/' + key['id'], update, cookie=cookie, origin=f.origin, csrf=csrf))['key']
        rotated = document(request(port, 'POST', '/api/keys/' + key['id'] + '/rotate', {'revision': disabled['revision']}, cookie=cookie, origin=f.origin, csrf=csrf), 201)
        f.secrets.append(rotated['secret'])
        assert not rotated['key']['enabled'] and rotated['key']['id'] == key['id']
        for token in (secret, rotated['secret']):
            assert request(f.ports['data'], 'GET', '/v1/models', headers={'Authorization': 'Bearer ' + token})[0] == 401
        fresh = rotated['key']
        enabled = dict(revision=fresh['revision'], enabled=True, models=fresh['models'], limits=fresh['limits'])
        document(request(port, 'PUT', '/api/keys/' + key['id'], enabled, cookie=cookie, origin=f.origin, csrf=csrf))
        assert request(f.ports['data'], 'GET', '/v1/models', headers={'Authorization': 'Bearer ' + rotated['secret']})[0] == 200
        assert request(f.ports['data'], 'GET', '/v1/models', headers={'Authorization': 'Bearer ' + secret})[0] == 401
        for path in ('/', '/index.html', '/assets/entry.js', '/assets/entry.css'):
            result = request(port, 'GET', path)
            assert result[0] == 200 and result[1]['x-content-type-options'] == 'nosniff'
            assert "frame-ancestors 'none'" in result[1]['content-security-policy']
        assert request(port, 'GET', '/assets/entry.js')[1]['content-type'].startswith('text/javascript')
        for path in ('/.env', '/core.sqlite', '/admin', '/assets/../admin', '/assets/%2e%2e%2fadmin', '/assets/missing.js'):
            assert request(port, 'GET', path)[0] == 404
        for _ in range(15):
            login(f)
        assert request(port, 'POST', '/api/session', {'secret': ADMIN}, origin=f.origin)[0] == 503
        # Re-authentication replaces the caller's session, including at capacity; old proof dies.
        fresh_cookie, fresh_csrf = login(f, cookie=cookie)
        assert request(port, 'GET', '/api/session', cookie=cookie)[0] == 401
        logout = request(port, 'DELETE', '/api/session', cookie=fresh_cookie, origin=f.origin, csrf=fresh_csrf)
        document(logout)
        assert 'Max-Age=0' in logout[1]['set-cookie']
        assert request(port, 'GET', '/api/session', cookie=fresh_cookie)[0] == 401
        surviving_cookie, _ = login(f)
        shutdown(f.process, f.root, f.secrets)
        f.process = None
        f.process, f.ports = start(binary, f.config, f.root, admin_token_file=f.admin, web_directory=f.web_directory,
                                 admin_public_origin='https://admin.example:443/')
        port = f.ports['admin']
        assert request(port, 'GET', '/api/session', cookie=surviving_cookie)[0] == 401
        assert request(port, 'POST', '/api/session', {'secret': ADMIN}, origin=f.origin)[0] == 403
        cookie, csrf = login(f, cookie=surviving_cookie, origin='https://admin.example')
        assert request(port, 'GET', '/api/session', cookie=cookie, origin='https://foreign.example', headers={'X-Forwarded-Host': 'admin.example'})[0] == 403
        for path in (f.root / 'state').glob('core.sqlite*'):
            assert all(secret.encode() not in path.read_bytes() for secret in f.secrets + [ADMIN])
        # Asset validation rejects links before opening them and never creates a core database.
        link = f.web_directory / 'assets/private.js'
        link.symlink_to(f.admin)
        result = subprocess.run([binary, '--check-config'], env={'PATH': os.defpath, 'CODEXONE_WEB_DIRECTORY': str(f.web_directory)}, capture_output=True, timeout=3)
        assert result.returncode != 0 and ADMIN.encode() not in result.stdout + result.stderr and str(f.root).encode() not in result.stdout + result.stderr
        link.unlink()
        print('PASS: real management sessions: exact Origin/Host and CSRF, secure cookies, logout/restart/capacity, Key actions, bounded static assets and secret-free storage/output')


def verify_account_configuration(binary):
    # Starting an authorization flow creates only a URL; no real token endpoint is called.
    with running_admin(binary, account_master=True) as f:
        port = f.ports['admin']
        cookie, csrf = login(f)
        auth = dict(cookie=cookie, csrf=csrf, origin=f.origin)
        assert document(request(port, 'GET', '/api/accounts', cookie=cookie))['accounts'] == []
        flow = document(request(port, 'POST', '/api/accounts/authorization', {'target': None}, **auth))
        assert flow['authorizationURL'].startswith('https://auth.openai.com/oauth/authorize?')
        # Wrong state consumes before any network dispatch, then replay conflicts.
        body = {'callbackURL': 'http://localhost:1455/auth/callback?code=synthetic&state=wrong'}
        path = '/api/accounts/authorization/' + flow['flowID']
        assert request(port, 'POST', path, body, **auth)[0] == 400
        assert request(port, 'POST', path, body, **auth)[0] == 409
        document(request(port, 'DELETE', path, **auth))
        master = f.root / 'master'
        check_directory = f.root / 'check-only'
        env = {'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(check_directory),
               'CODEXONE_ADMIN_TOKEN_FILE': str(f.admin), 'CODEXONE_ACCOUNT_MASTER_KEY_FILE': str(master)}
        def check(expected_success):
            result = subprocess.run([binary, '--check-config'], env=env, capture_output=True, timeout=5)
            assert (result.returncode == 0) == expected_success
            assert not check_directory.exists()
            output = result.stdout + result.stderr
            assert all(value.encode() not in output for value in [str(f.root), '5a' * 32, ADMIN])
        check(True)
        master.chmod(0o644)
        check(False)
        master.chmod(0o600)
        master.write_text('invalid-private-master-value')
        check(False)
        master.write_text('5a' * 32)
        duplicate_admin = f.root / 'duplicate-admin'
        duplicate_admin.write_text('5A' * 32)
        duplicate_admin.chmod(0o600)
        env['CODEXONE_ADMIN_TOKEN_FILE'] = str(duplicate_admin)
        check(False)
        print('PASS: account production assembly and private master validation; safe metadata, one-shot invalid callback before network; check-config has no DB or credential output')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    verify(binary)
    verify_account_configuration(binary)
