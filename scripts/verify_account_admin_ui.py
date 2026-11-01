#!/usr/bin/env python3
"""Real SPA + test-only runtime assembly + synthetic OAuth; never a personal account/profile."""
import argparse
import base64
import hashlib
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit
from browser_env import browser_env

CLIENT = 'app_EMoamEEZ73f0CkXaXp7hrann'
ADMIN = 'synthetic-account-ui-admin-' + 'a' * 32

def encoded(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')

def jwt(claims):
    return '.'.join([encoded(json.dumps({'alg': 'RS256'}).encode()), encoded(json.dumps(claims).encode()), encoded(b'synthetic-signature')])

class SyntheticOAuth(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def reply(self, body, status=200, content_type='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/backend-api/wham/usage':
            with self.server.guard:
                assert self.headers.get('Authorization', '').removeprefix('Bearer ') in self.server.issued
                assert self.headers.get('ChatGPT-Account-Id') == 'synthetic-account'
                assert self.headers.get('x-openai-codex-luna-reserve') is None
                self.server.quota_calls += 1
                mode = self.server.control.get('quota_mode', 'ok')
            if mode == 'restricted':
                return self.reply({'rate_limit': {'allowed': False, 'limit_reached': True}})
            if mode == 'fail':
                return self.reply({'error': 'synthetic-private-quota-marker'}, status=500)
            return self.reply({'private_field': 'synthetic-private-quota-marker', 'rate_limit': {
                'allowed': True, 'limit_reached': False,
                'primary_window': {'used_percent': 25, 'limit_window_seconds': 18000, 'reset_at': int(time.time()) + 3600},
                'secondary_window': {'used_percent': 45, 'limit_window_seconds': 604800, 'reset_at': int(time.time()) + 86400}},
                'additional_rate_limits': [{'metered_feature': 'synthetic-extra', 'rate_limit': {'primary_window': {'used_percent': 10}}}]})
        if self.path == '/codex/device':
            return self.reply(b'<!doctype html><html><title>Synthetic device</title><h1>Device authorization</h1><a href="/__approve">Approve synthetic device</a></html>', content_type='text/html; charset=utf-8')
        if self.path == '/__approve':
            with self.server.guard:
                self.server.control['device_approved'] = True
            return self.reply(b'<!doctype html><html><h1>Device approved</h1></html>', content_type='text/html; charset=utf-8')
        query = parse_qs(urlsplit(self.path).query)
        assert urlsplit(self.path).path == '/oauth/authorize'
        callback = 'http://localhost:1455/auth/callback?' + urlencode({'state': query['state'][0], 'code': 'synthetic-code+/='})
        self.reply(('<!doctype html><html lang="zh"><title>合成订阅登录</title><h1>合成订阅授权</h1><a href="' + html.escape(callback, quote=True) + '">复制合成回调地址</a></html>').encode(), content_type='text/html; charset=utf-8')
    def do_POST(self):
        size = int(self.headers.get('content-length', '0'))
        assert 0 < size <= 65536
        raw = self.rfile.read(size)
        if self.path == '/__fixture':
            value = json.loads(raw)
            with self.server.guard:
                self.server.control.update(value)
            return self.reply({'ok': True})
        if self.path == '/api/accounts/deviceauth/usercode':
            assert json.loads(raw) == {'client_id': CLIENT}
            with self.server.guard:
                self.server.control.update(device_approved=False)
            return self.reply({'device_auth_id': 'synthetic-device-id-private', 'user_code': 'SYNTH-CODE', 'interval': '3'})
        if self.path == '/api/accounts/deviceauth/token':
            assert json.loads(raw) == {'device_auth_id': 'synthetic-device-id-private', 'user_code': 'SYNTH-CODE'}
            with self.server.guard:
                approved = self.server.control.get('device_approved', False)
            if not approved:
                return self.reply({}, status=403)
            verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
            return self.reply({'authorization_code': 'synthetic-code+/=', 'code_verifier': verifier,
                               'code_challenge': encoded(hashlib.sha256(verifier.encode()).digest())})
        assert self.path == '/oauth/token'
        if self.headers.get('content-type') == 'application/x-www-form-urlencoded':
            value = {key: values[0] for key, values in parse_qs(raw.decode()).items()}
        else:
            value = json.loads(raw)
        with self.server.guard:
            self.server.calls += 1
            control = self.server.control.copy()
        assert value['client_id'] == CLIENT
        if value['grant_type'] == 'authorization_code':
            assert value['code'] == 'synthetic-code+/='
            if value['redirect_uri'].endswith('/deviceauth/callback'):
                assert value['redirect_uri'] == 'http://127.0.0.1:' + str(self.server.server_port) + '/deviceauth/callback'
                assert value['code_verifier'] == 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
            else:
                assert value['redirect_uri'] == 'http://localhost:1455/auth/callback'
                assert encoded(hashlib.sha256(value['code_verifier'].encode()).digest()) == control['challenge']
        else:
            assert value['grant_type'] == 'refresh_token' and value['refresh_token'].startswith('synthetic-refresh-')
            if control.get('mode') == 'reject':
                return self.reply({'error': 'invalid_grant'}, status=400)
        scope = {'chatgpt_account_id': 'synthetic-account', 'chatgpt_user_id': 'synthetic-user'}
        common = {'iss': 'https://auth.openai.com', 'sub': 'synthetic-subject', 'exp': int(time.time()) + 3600,
                  'https://api.openai.com/auth': scope}
        tokens = {'access_token': jwt(common), 'id_token': jwt(dict(common, aud=CLIENT, nonce=control.get('nonce', 'synthetic-device-no-nonce'))),
                  'refresh_token': 'synthetic-refresh-' + str(self.server.calls), 'token_type': 'Bearer', 'expires_in': 3600}
        with self.server.guard:
            self.server.issued.extend(tokens[key] for key in ['access_token', 'id_token', 'refresh_token'])
        self.reply(tokens)

def verify(binary, usage=False):
    root = Path(__file__).resolve().parents[1]
    provider = ThreadingHTTPServer(('127.0.0.1', 0), SyntheticOAuth)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.control = {}
    provider.calls = 0
    provider.quota_calls = 0
    provider.issued = []
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-account-ui-') as temporary:
            work = Path(temporary)
            for name, value in [('admin', ADMIN), ('master', '6b' * 32)]:
                (work / name).write_text(value)
                (work / name).chmod(0o600)
            process = subprocess.Popen([binary, '--usage-admin-ui' if usage else '--account-admin-ui', str(work), str(root / 'web/dist'), str(provider.server_port)],
                                       env={'PATH': os.defpath}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = b''
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 10
                    while b'ADMIN_PORT ' not in output:
                        assert time.monotonic() < deadline and process.poll() is None, 'Synthetic UI assembly did not start'
                        if selector.select(.1):
                            chunk = os.read(process.stdout.fileno(), 4096)
                            assert chunk
                            output += chunk
                port = int(re.search(rb'ADMIN_PORT (\d+)', output)[1])
                result = subprocess.run(['node', str(root / ('web/scripts/live-usage.mjs' if usage else 'web/scripts/live-accounts.mjs')), str(port), str(provider.server_port), str(root / ('artifacts/usage-ui' if usage else 'artifacts/account-management-ui'))],
                                        input=json.dumps({'credential': ADMIN}).encode(), capture_output=True, timeout=120,
                                        env=browser_env())
                browser_output = result.stdout + result.stderr
                assert len(browser_output) < 65536 and ADMIN.encode() not in browser_output and str(work).encode() not in browser_output
                assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}', browser_output) is None
                assert result.returncode == 0, 'Browser account verification failed; private inputs excluded: ' + browser_output.decode()
                print(browser_output.decode(), end='')
                with provider.guard:
                    issued = list(provider.issued)
                    assert (provider.calls == 0 and provider.quota_calls == 0) if usage else (provider.calls == 3 and provider.quota_calls >= 3)
                for file in (work / 'state').glob('core.sqlite*'):
                    assert all(value.encode() not in file.read_bytes() for value in issued + [ADMIN, '6b' * 32, 'synthetic-private-quota-marker', 'SYNTH-CODE', 'synthetic-device-id-private'])
            finally:
                process.terminate()
                try:
                    output += process.communicate(timeout=10)[0]
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    raise AssertionError('Synthetic UI assembly failed to stop')
                assert process.returncode == 0
                assert len(output) < 65536 and ADMIN.encode() not in output and str(work).encode() not in output
                assert all(value.encode() not in output for value in provider.issued + ['SYNTH-CODE', 'synthetic-device-id-private'])
    finally:
        provider.shutdown()
        provider.server_close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--usage', action='store_true')
    args = parser.parse_args()
    verify(str(args.binary.resolve()), usage=args.usage)
