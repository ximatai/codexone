"""Private synthetic OAuth and managed Rust gateway setup for verification scripts."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.client import RemoteDisconnected
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hashlib
import html
import json
import os
import re
import selectors
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit

from verify_admin import document, request
from verify_process import environment, release


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
        if urlsplit(self.path).path == '/backend-api/codex/models':
            with self.server.guard:
                assert self.headers.get('Authorization', '').removeprefix('Bearer ') in self.server.issued
                assert self.headers.get('ChatGPT-Account-Id') == 'synthetic-account'
                fail = self.server.control.get('model_discovery_failure')
                changed = self.server.control.get('model_changed')
                delay = self.server.control.get('model_discovery_delay', 0)
            assert parse_qs(urlsplit(self.path).query).get('client_version')
            if fail:
                return self.reply({'error': 'synthetic-catalog-unavailable'}, status=503)
            if delay:
                time.sleep(delay)
            return self.reply({'models': [
                {'slug': 'synthetic-nova', 'visibility': 'list', 'base_instructions': 'Synthetic model guidance.',
                 'input_modalities': ['text', 'image'] if changed else ['text'],
                 'supported_reasoning_levels': ([{'effort': 'low', 'description': 'Low'}] if changed else []) + [{'effort': 'high', 'description': 'High'}],
                 'default_reasoning_level': 'high'},
                {'slug': 'synthetic-incomplete', 'visibility': 'list'},
            ]})
        if self.path == '/backend-api/wham/rate-limit-reset-credits':
            return self.reply({'available_count': 0, 'credits': []})
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
            return self.reply({'private_field': 'synthetic-private-quota-marker',
                'credits': {'balance': '12.500', 'unlimited': False},
                'rate_limit': {
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
            if gate := control.get('refresh_gate'):
                dispatched, disconnect = gate
                dispatched.set()
                assert disconnect.wait(timeout=10)
                self.close_connection = True
                return
            if control.get('mode') == 'timeout':
                # Leave the dispatched refresh without a terminal response.
                time.sleep(12)
                self.close_connection = True
                return
            if control.get('mode') == 'reject':
                return self.reply({'error': 'invalid_grant'}, status=400)
        scope = {'chatgpt_account_id': control.get('identity', 'synthetic-account'), 'chatgpt_user_id': 'synthetic-user'}
        common = {'iss': 'https://auth.openai.com', 'sub': 'synthetic-subject', 'exp': int(time.time()) + 3600,
                  'https://api.openai.com/auth': scope}
        tokens = {'access_token': jwt(common), 'id_token': jwt(dict(common, aud=CLIENT, nonce=control.get('nonce', 'synthetic-device-no-nonce'))),
                  'refresh_token': 'synthetic-refresh-' + str(self.server.calls), 'token_type': 'Bearer', 'expires_in': 3600}
        with self.server.guard:
            self.server.issued.extend(tokens[key] for key in ['access_token', 'id_token', 'refresh_token'])
        self.reply(tokens)


AUTH = {'headers': {'Authorization': 'Bearer ' + ADMIN}}


@contextmanager
def oauth_provider():
    with ThreadingHTTPServer(('127.0.0.1', 0), SyntheticOAuth) as server:
        server.guard = threading.Lock()
        server.control = {}
        server.calls = server.quota_calls = 0
        server.issued = []
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join(timeout=5)
            assert not worker.is_alive()


def private_file(path, value):
    path.write_text(value)
    path.chmod(0o600)


def prepare(root, master='6b' * 32, *, model='synthetic-text'):
    (root / 'state').mkdir(mode=0o700)
    private_file(root / 'admin', ADMIN)
    private_file(root / 'master', master)
    private_file(root / 'pool.json', json.dumps({
        'models': [{'id': model, 'inputMicrosPerMillion': 0, 'outputMicrosPerMillion': 0}],
        'reservedMicros': 10,
    }))
    return root / 'state/core.sqlite'


def managed_environment(root, master=None):
    return environment(
        PATH=os.defpath,
        CODEXONE_ACCOUNT_POOL_CONFIG=str(root / 'pool.json'),
        CODEXONE_ACCOUNT_MASTER_KEY_FILE=str(master or root / 'master'),
        CODEXONE_ADMIN_TOKEN_FILE=str(root / 'admin'),
        CODEXONE_DATA_DIRECTORY=str(root / 'state'),
    )


def listening(process, pattern):
    deadline = time.monotonic() + 15
    output = b''
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(.1):
                continue
            chunk = os.read(process.stdout.fileno(), 4096)
            assert chunk, 'Synthetic gateway exited before listening'
            output += chunk
            assert len(output) <= 65536
            match = re.search(pattern, output)
            if match:
                return int(match[1]), output
    raise AssertionError('Synthetic gateway did not listen within budget')


def start_gateway(probe, root, provider, *, web=None, master=None):
    env = managed_environment(root, master)
    env['CODEXONE_MANAGED_TEST_PORT'] = str(provider.server_port)
    if web:
        env['CODEXONE_WEB_DIRECTORY'] = str(web)
    command = [probe, '--exact', 'managed_process::child', '--nocapture']
    pattern = rb'LISTENING admin 127\.0\.0\.1:(\d+)'
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        port, output = listening(process, pattern)
        return process, port, output
    except BaseException:
        release(process)
        raise


def authorize(port, provider, *, identity='synthetic-account'):
    flow = document(request(port, 'POST', '/api/accounts/authorization', {'target': None, 'method': 'callback'}, **AUTH))
    query = parse_qs(urlsplit(flow['authorizationURL']).query)
    with provider.guard:
        provider.control.update(challenge=query['code_challenge'][0], nonce=query['nonce'][0], identity=identity)
    callback = 'http://localhost:1455/auth/callback?' + urlencode({'state': query['state'][0], 'code': 'synthetic-code+/='})
    return document(request(port, 'POST', '/api/accounts/authorization/' + flow['flowID'], {'callbackURL': callback}, **AUTH))['account']


def refresh(port, account):
    return request(port, 'POST', '/api/accounts/' + account['id'] + '/refresh',
                   {'revision': account['revision']}, **AUTH)


@contextmanager
def dispatched_refresh(port, provider, account):
    dispatched, disconnect = threading.Event(), threading.Event()
    with provider.guard:
        provider.control['refresh_gate'] = (dispatched, disconnect)
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(refresh, port, account)
        try:
            assert dispatched.wait(timeout=5), 'Synthetic refresh did not reach the provider'
            yield pending
        finally:
            disconnect.set()
            with provider.guard:
                provider.control.pop('refresh_gate')


def kill(process):
    process.kill()
    assert process.wait(timeout=5) == -signal.SIGKILL


def assert_disconnected(pending):
    try:
        pending.result(timeout=5)
    except (RemoteDisconnected, ConnectionResetError):
        return
    raise AssertionError('The killed gateway returned a refresh response')


def assert_refresh_denied(port, account):
    status, _, body = refresh(port, account)
    assert status == 409 and json.loads(body)['error']['code'] == 'account_conflict'
