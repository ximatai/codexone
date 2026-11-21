"""Private synthetic OAuth and managed Rust gateway setup for verification scripts."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.client import RemoteDisconnected
from http.server import ThreadingHTTPServer
import json
import os
import re
import selectors
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit

from verify_account_admin_ui import ADMIN, SyntheticOAuth
from verify_admin import document, request
from verify_process import environment, release


AUTH = {'headers': {'Authorization': 'Bearer ' + ADMIN}}


@contextmanager
def oauth_provider(*, rust):
    with ThreadingHTTPServer(('127.0.0.1', 0), SyntheticOAuth) as server:
        server.rust = rust
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


def prepare(root, master='6b' * 32):
    (root / 'state').mkdir(mode=0o700)
    private_file(root / 'admin', ADMIN)
    private_file(root / 'master', master)
    private_file(root / 'pool.json', json.dumps({
        'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 0, 'outputMicrosPerMillion': 0}],
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


def start_gateway(probe, root, provider, *, rust, web=None, master=None, proxy=None):
    if rust:
        env = managed_environment(root, master)
        env['CODEXONE_MANAGED_TEST_PORT'] = str(provider.server_port)
        if web:
            env['CODEXONE_WEB_DIRECTORY'] = str(web)
        command = [probe, '--exact', 'managed_process::child', '--nocapture']
        pattern = rb'LISTENING admin 127\.0\.0\.1:(\d+)'
    else:
        env = {'PATH': os.defpath}
        command = [probe, '--account-admin-ui', str(root), str(web), str(provider.server_port)]
        pattern = rb'ADMIN_PORT (\d+)'
    if proxy:
        env['CODEXONE_UPSTREAM_HTTP_PROXY'] = f'http://127.0.0.1:{proxy}'
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
