#!/usr/bin/env python3
"""Real local TLS/Nginx sockets, synthetic upstream, private ledger and optional Chrome."""
import argparse
import base64
from contextlib import contextmanager, ExitStack
import hashlib
import http.client
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import secrets
import signal
import shutil
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
from unittest.mock import patch

from verify_protocol import start, stop, latest
from verify_websocket import exact, send, receive, turn

REPO = Path(__file__).resolve().parents[1]
MODEL = 'synthetic-text'


def command(arguments, *, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=20)
    assert result.returncode == 0, 'Local TLS tool failed; private diagnostics withheld'
    return result.stdout


def certificate(root, openssl):
    # No system trust-store changes; one disposable CA and one SAN leaf.
    command([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=CodexOne synthetic TLS CA', '-keyout', str(root / 'ca.key'), '-out', str(root / 'ca.crt'),
             '-addext', 'basicConstraints=critical,CA:TRUE'])
    command([openssl, 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
             '-keyout', str(root / 'server.key'), '-out', str(root / 'server.csr')])
    (root / 'extensions').write_text('subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n')
    command([openssl, 'x509', '-req', '-in', str(root / 'server.csr'), '-CA', str(root / 'ca.crt'),
             '-CAkey', str(root / 'ca.key'), '-CAcreateserial', '-days', '1', '-extfile', str(root / 'extensions'),
             '-out', str(root / 'server.crt')])
    public = command([openssl, 'x509', '-in', str(root / 'server.crt'), '-pubkey', '-noout'])
    der = command([openssl, 'pkey', '-pubin', '-outform', 'DER'], data=public)
    return ssl.create_default_context(cafile=str(root / 'ca.crt')), base64.b64encode(hashlib.sha256(der).digest()).decode()


class SyntheticProvider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def do_GET(self):
        assert self.path == '/v1/responses' and self.headers.get('Authorization') is None
        assert self.headers.get('Forwarded') is None
        nonce = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
        with self.server.guard:
            self.server.connections += 1
            connection = self.server.connections
        stalled = False
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    if stalled: self.server.cancelled.set()
                    return
                assert opcode == 1
                create = json.loads(data); assert create['type'] == 'response.create'
                with self.server.guard:
                    self.server.calls += 1
                    index = self.server.calls
                previous = create.get('previous_response_id')
                assert previous is None or previous.startswith(f'resp_ws_tls_{connection}_')
                if create['input'] == 'tls-ws-cancel':
                    stalled = True; self.server.entered.set()
                    self.connection.settimeout(5)
                    try:
                        opcode, _ = receive(self.connection, masked=True)
                        assert opcode == 8
                        self.server.cancelled.set()
                    except (EOFError, ConnectionResetError): self.server.cancelled.set()
                    return
                response = dict(id=f'resp_ws_tls_{connection}_{index}', status='completed', output=[],
                    usage=dict(input_tokens=5, output_tokens=3, input_tokens_details=dict(cached_tokens=0)))
                send(self.connection, dict(type='response.created', response={**response, 'status': 'in_progress', 'usage': None}))
                send(self.connection, dict(type='response.completed', response=response))
        except (EOFError, ConnectionResetError, BrokenPipeError):
            if stalled: self.server.cancelled.set()
        finally:
            self.close_connection = True

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        assert 0 < length <= 524288
        payload = json.loads(self.rfile.read(length))
        assert self.path == '/v1/responses'
        assert self.headers.get('Authorization') is None
        assert all(self.headers.get(name) is None for name in ('Forwarded', 'X-Forwarded-For', 'X-Forwarded-Host', 'X-Forwarded-Proto', 'X-Real-IP'))
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        response = {'id': f'resp_tls_{index}', 'object': 'response', 'status': 'completed', 'model': MODEL,
            'output': [], 'usage': {'input_tokens': 5, 'output_tokens': 3, 'input_tokens_details': {'cached_tokens': 0}}}
        prompt = payload.get('input')
        try:
            if prompt == 'tls-preheader-timeout':
                self.server.entered.set()
                self.connection.settimeout(5)
                if not self.connection.recv(1): self.server.cancelled.set()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream' if payload.get('stream') else 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            if not payload.get('stream'):
                self.wfile.write(json.dumps(response).encode())
                return
            def event(value):
                self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
                self.wfile.flush()
            event({'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'usage': None}})
            self.server.entered.set()
            if prompt in ('tls-cancel', 'tls-timeout'):
                self.connection.settimeout(5)
                if not self.connection.recv(1): self.server.cancelled.set()
                return
            if prompt == 'tls-stream':
                assert self.server.release.wait(5), 'Streaming terminal was not released'
            event({'type': 'response.completed', 'response': response})
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            if prompt in ('tls-cancel', 'tls-timeout', 'tls-preheader-timeout'): self.server.cancelled.set()
        finally:
            self.close_connection = True


def reserve_ports():
    sockets = [socket.socket(), socket.socket()]
    try:
        for sock in sockets: sock.bind(('127.0.0.1', 0))
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets: sock.close()


def quoted(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


class Proxy:
    def __init__(self, root, tls, ports, public_ports, nginx):
        self.root, self.nginx = root, nginx
        root.mkdir(mode=0o700)
        self.config = root / 'nginx.conf'
        data = (REPO / 'deploy/nginx-data.conf').read_text().replace('127.0.0.1:18080', '127.0.0.1:' + str(ports['data']))
        admin = (REPO / 'deploy/nginx-admin.conf').read_text().replace('127.0.0.1:18081', '127.0.0.1:' + str(ports['admin']))
        (root / 'data.conf').write_text(data); (root / 'admin.conf').write_text(admin)
        example = (REPO / 'deploy/nginx.conf.example').read_text()
        for port in public_ports:
            example = example.replace('listen 443 ssl;', f'listen 127.0.0.1:{port} ssl;', 1)
        example = example.replace('data.example.invalid', 'localhost').replace('admin.example.invalid', 'localhost')
        for name in ('data', 'admin'):
            example = example.replace(f'/etc/codexone/tls/{name}.crt', quoted(tls / 'server.crt'))
            example = example.replace(f'/etc/codexone/tls/{name}.key', quoted(tls / 'server.key'))
            example = example.replace(f'/etc/nginx/snippets/codexone-{name}.conf', quoted(root / (name + '.conf')))
        temporary_paths = ''.join(name + '_temp_path ' + quoted(root / name) + ';\n' for name in ('proxy', 'fastcgi', 'uwsgi', 'scgi'))
        self.config.write_text('worker_processes 1;\npid ' + quoted(root / 'nginx.pid') + ';\nerror_log ' + quoted(root / 'error.log') + ' crit;\nevents { worker_connections 64; }\nhttp { access_log off; client_body_temp_path ' + quoted(root / 'bodies') + ';\n' + temporary_paths + example + '\n}\n')
        command([nginx, '-e', str(root / 'error.log'), '-p', str(root), '-c', str(self.config), '-t'])
        self.logs = (root / 'process.log').open('w+b')
        try:
            self.process = subprocess.Popen([nginx, '-e', str(root / 'error.log'), '-p', str(root), '-c', str(self.config), '-g', 'daemon off;'], stdout=self.logs, stderr=self.logs, start_new_session=True)
        except BaseException:
            self.logs.close()
            raise

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=3)
        finally:
            # A crashed/killed master can leave its worker holding the listeners.
            try: os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            # In a PID-1 test container orphan workers can become our children.
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    child, _ = os.waitpid(-self.process.pid, os.WNOHANG)
                    if child == 0:
                        time.sleep(0.02)
                        continue
                except ChildProcessError: break
            self.logs.close()
        assert self.process.returncode == 0, 'Nginx did not exit gracefully'


def finish_gateway(process, root, known_secrets, release):
    release.set()
    try:
        process.terminate(); process.wait(timeout=10)
        logs = process.stdout.read(131073)
        assert process.returncode == 0 and len(logs) < 131072
        assert str(root).encode() not in logs
        assert all(value.encode() not in logs for value in known_secrets)
        assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}', logs) is None
    finally: stop(process)


def finish_provider(provider, thread):
    provider.release.set(); provider.shutdown(); thread.join(timeout=2)
    assert not thread.is_alive(), 'Synthetic provider loop did not stop'


@contextmanager
def fixture(args, parent, tls, context, transport):
    # Register each owner immediately. ExitStack continues every callback even
    # when an earlier close or its verification raises.
    with ExitStack() as owners:
        root = parent / transport; root.mkdir(mode=0o700)
        provider = ThreadingHTTPServer(('127.0.0.1', 0), SyntheticProvider)
        owners.callback(provider.server_close)
        provider.daemon_threads = True
        provider.calls = provider.connections = 0
        provider.guard = threading.Lock()
        provider.entered = threading.Event(); provider.release = threading.Event(); provider.cancelled = threading.Event()
        admin_secret = secrets.token_urlsafe(40)
        admin = root / 'admin'; admin.write_text(admin_secret); admin.chmod(0o600)
        public_ports = reserve_ports()
        config = root / 'identity.json'
        config.write_text(json.dumps(dict(managedKeys=True, namespace='synthetic-tls', identity='synthetic-account',
            reservedMicros=10, executionTimeoutSeconds=8, upstreamTransport=transport,
            upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1',
            models=[dict(id=MODEL, inputMicrosPerMillion=0, outputMicrosPerMillion=0,
                         catalog=dict(baseInstructions='Explicit synthetic TLS fixture guidance'))])))
        config.chmod(0o600)
        thread = threading.Thread(target=provider.serve_forever, daemon=True); thread.start()
        owners.callback(finish_provider, provider, thread)
        process, ports = start(str(args.binary.resolve()), config, root, admin_token_file=admin,
            web_directory=args.web.resolve(), admin_public_origin=f'https://localhost:{public_ports[1]}')
        known_secrets = [admin_secret]
        owners.callback(finish_gateway, process, root, known_secrets, provider.release)
        proxy = Proxy(root / 'proxy', tls, ports, public_ports, args.nginx)
        owners.callback(proxy.close)
        value = dict(root=root, provider=provider, providerThread=thread, gatewayPorts=ports,
            process=process, proxy=proxy, ports=public_ports, context=context,
            admin=admin_secret, secrets=known_secrets, origin=f'https://localhost:{public_ports[1]}')
        deadline = time.monotonic() + 5
        while True:
            assert proxy.process.poll() is None, 'Private Nginx exited'
            try:
                if request(value, 'admin', 'GET', '/health/live')[0] == 200: break
            except OSError: pass
            assert time.monotonic() < deadline, 'Private TLS proxy did not listen'
            time.sleep(0.05)
        yield value


def connection(f, plane):
    return http.client.HTTPSConnection('localhost', f['ports'][1 if plane == 'admin' else 0], context=f['context'], timeout=4)


def request(f, plane, method, path, payload=None, headers=None):
    client = connection(f, plane)
    try:
        fields = {'Content-Type': 'application/json', **(headers or {})}
        client.request(method, path, body=json.dumps(payload) if payload is not None else None, headers=fields)
        response = client.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally: client.close()


def token(f):
    status, _, body = request(f, 'admin', 'POST', '/api/keys', dict(principal='synthetic-tls-protocol', models=[MODEL],
        limits=dict(requests=100, active=4, unresolved=16, budgetMicros=1000000, unresolvedMicros=1000000)),
        {'Authorization': 'Bearer ' + f['admin']})
    assert status == 201
    result = json.loads(body)['secret']; f['secrets'].append(result)
    return result


def ledger(f):
    with sqlite3.connect(f['root'] / 'state/core.sqlite') as db:
        return db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]


def trust_checks(f):
    for context, hostname in ((ssl.create_default_context(), 'localhost'), (f['context'], 'wrong.example.invalid')):
        try:
            with socket.create_connection(('127.0.0.1', f['ports'][0]), timeout=3) as raw:
                with context.wrap_socket(raw, server_hostname=hostname): pass
        except ssl.SSLCertVerificationError: pass
        else: raise AssertionError('Untrusted certificate or mismatched hostname accepted')
    with socket.create_connection(('127.0.0.1', f['ports'][0]), timeout=3) as raw:
        with f['context'].wrap_socket(raw, server_hostname='localhost') as client:
            assert client.version() in ('TLSv1.2', 'TLSv1.3')
    print('PASS: real TLS chain/hostname validation; missing trust and wrong hostname rejected')


def admin_checks(f, key):
    origin = f['origin']
    assert request(f, 'admin', 'GET', '/api/keys')[0] == 401
    assert request(f, 'admin', 'GET', '/api/keys', headers={'Authorization': 'Bearer ' + key})[0] == 401
    forged = {'Origin': origin, 'Host': 'wrong.example.invalid', 'Forwarded': 'host=localhost;proto=https',
              'X-Forwarded-Host': origin.removeprefix('https://'), 'X-Forwarded-Proto': 'https'}
    assert request(f, 'admin', 'POST', '/api/session', {'secret': f['admin']}, forged)[0] == 403
    for bad_origin in ('https://wrong.example.invalid', 'https://localhost'):
        assert request(f, 'admin', 'POST', '/api/session', {'secret': f['admin']}, {'Origin': bad_origin})[0] == 403
    assert request(f, 'admin', 'POST', '/api/session', {'secret': f['admin']}, {'Origin': origin, 'Host': 'localhost'})[0] == 403
    status, headers, body = request(f, 'admin', 'POST', '/api/session', {'secret': f['admin']}, {'Origin': origin})
    assert status == 200
    cookie = SimpleCookie(); cookie.load(headers['set-cookie']); session = cookie['__Host-codexone_admin']
    assert session['secure'] and session['httponly'] and session['samesite'] == 'Strict' and session['path'] == '/'
    csrf = json.loads(body)['csrf']; f['secrets'] += [session.value, csrf]
    fields = {'Cookie': '__Host-codexone_admin=' + session.value, 'Origin': origin}
    assert request(f, 'admin', 'POST', '/api/keys', {}, fields)[0] == 403
    assert request(f, 'admin', 'POST', '/api/keys', {}, {**fields, 'X-CodexOne-CSRF': 'wrong'})[0] == 403
    assert request(f, 'admin', 'GET', '/api/keys', headers=fields)[0] == 200
    for path in ('/', '/api/keys', '/health/live'):
        assert request(f, 'data', 'GET', path)[0] == 404
    for prefix in ('/v1', '/backend-api/codex'):
        assert request(f, 'admin', 'GET', prefix + '/models', headers={'Authorization': 'Bearer ' + key})[0] == 404
    # Host/Origin remain exact, including the non-default TLS port.
    assert request(f, 'admin', 'DELETE', '/api/session', headers={**fields, 'X-CodexOne-CSRF': csrf})[0] == 200
    assert request(f, 'admin', 'GET', '/api/session', headers=fields)[0] == 401
    print('PASS: real HTTPS session/CSRF, exact Host+Origin/port, forwarded spoof refusal and data/admin isolation')


def limits_checks(f, key):
    before, calls = ledger(f), f['provider'].calls
    for plane, size, path in (('data', 8 * 1024 * 1024 + 1, '/v1/responses'), ('admin', 8193, '/api/session')):
        client = connection(f, plane)
        try:
            # Content-Length alone must refuse an oversized body before gateway dispatch.
            client.putrequest('POST', path)
            client.putheader('Content-Length', str(size)); client.putheader('Authorization', 'Bearer ' + key)
            client.endheaders()
            response = client.getresponse(); assert response.status == 413; response.read()
        finally: client.close()
    assert ledger(f) == before and f['provider'].calls == calls
    assert request(f, 'data', 'POST', '/v1/responses', {'model': MODEL, 'input': 'x' * 16384}, {'Authorization': 'Bearer ' + key})[0] == 200
    print('PASS: actual Nginx data/admin body limits refuse before dispatch; bounded normal body passes')


def stream_checks(f, key):
    provider = f['provider']; headers = {'Accept-Encoding': 'gzip', 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key, 'Forwarded': 'for=synthetic',
        'X-Forwarded-For': '192.0.2.1', 'X-Forwarded-Host': 'wrong.example.invalid', 'X-Forwarded-Proto': 'http'}
    for prefix in ('/v1', '/backend-api/codex'):
        assert request(f, 'data', 'GET', prefix + '/models')[0] == 401
        assert request(f, 'data', 'GET', prefix + '/models', headers=headers)[0] == 200
        assert request(f, 'data', 'POST', prefix + '/responses', {'model': MODEL, 'input': 'tls-json'}, headers)[0] == 200
    marker = 'synthetic-query-' + secrets.token_hex(8); f['secrets'].append(marker)
    assert request(f, 'data', 'GET', '/v1/models?probe=' + marker, headers=headers)[0] == 200
    provider.release.clear(); provider.entered.clear()
    client = connection(f, 'data')
    try:
        client.request('POST', '/v1/responses', body=json.dumps({'model': MODEL, 'input': 'tls-stream', 'stream': True}), headers=headers)
        response = client.getresponse(); assert response.status == 200
        assert 'text/event-stream' in response.getheader('content-type') and not response.getheader('content-encoding')
        # The provider cannot send a terminal until this client consumes created.
        line = response.readline(); assert b'response.created' in line and not provider.release.is_set()
        provider.release.set()
        assert b'response.completed' in response.read()
    finally: provider.release.set(); client.close()
    latest(f['root'] / 'state/core.sqlite', 'settled')
    provider.cancelled.clear(); provider.entered.clear(); before = provider.calls
    client = connection(f, 'data')
    client.request('POST', '/v1/responses', body=json.dumps({'model': MODEL, 'input': 'tls-cancel', 'stream': True}), headers=headers)
    response = client.getresponse(); assert response.status == 200
    assert b'response.created' in response.readline()
    response.close(); client.close()
    assert provider.cancelled.wait(3), 'TLS downstream cancellation did not reach provider'
    latest(f['root'] / 'state/core.sqlite', 'unknown')
    assert provider.calls == before + 1, 'Proxy replayed a cancelled generation'
    print('PASS: both TLS data prefixes, JSON, incremental unbuffered SSE and cancellation -> upstream close/unknown without replay')


def websocket_checks(f, key):
    for prefix in ('/v1', '/backend-api/codex'):
        with socket.create_connection(('127.0.0.1', f['ports'][0]), timeout=4) as raw:
            with f['context'].wrap_socket(raw, server_hostname='localhost') as sock:
                nonce = base64.b64encode(os.urandom(16)).decode()
                sock.sendall((f'GET {prefix}/responses HTTP/1.1\r\nHost: localhost:{f["ports"][0]}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {nonce}\r\nAuthorization: Bearer {key}\r\n\r\n').encode())
                header = bytearray()
                while not header.endswith(b'\r\n\r\n'):
                    header.extend(exact(sock, 1)); assert len(header) < 16384
                assert b' 101 ' in header
                expected = base64.b64encode(hashlib.sha1((nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                assert expected.lower() in header.lower()
                first = turn(sock, {'model': MODEL, 'input': 'tls-first', 'store': False})[-1]
                assert first['type'] == 'response.completed'
                assert turn(sock, {'model': MODEL, 'input': 'tls-next', 'previous_response_id': first['response']['id']})[-1]['type'] == 'response.completed'
                if prefix == '/backend-api/codex':
                    f['provider'].entered.clear(); f['provider'].cancelled.clear()
                    before = f['provider'].calls
                    send(sock, {'type': 'response.create', 'model': MODEL, 'input': 'tls-ws-cancel'}, masked=True)
                    assert f['provider'].entered.wait(3)
                else:
                    send(sock, b'\x03\xe8', masked=True, opcode=8)
        if prefix == '/backend-api/codex':
            assert f['provider'].cancelled.wait(3), 'WSS cancellation did not close provider'
            latest(f['root'] / 'state/core.sqlite', 'unknown')
            assert f['provider'].calls == before + 1
    assert request(f, 'data', 'POST', '/v1/responses', {'model': MODEL, 'input': 'tls-bridge', 'stream': True}, {'Authorization': 'Bearer ' + key})[0] == 200
    print('PASS: real WSS upgrade/accept, both prefixes, same-connection follow-up, WSS cancellation/unknown without replay and HTTP-to-WS bridge over TLS')


def timeout_checks(f, key):
    proxy = f['proxy']
    proxy.close()
    path = proxy.root / 'data.conf'
    path.write_text(path.read_text().replace('proxy_read_timeout 130s;', 'proxy_read_timeout 1s;').replace('client_body_timeout 30s;', 'client_body_timeout 1s;'))
    proxy.logs = (proxy.root / 'process.log').open('a+b')
    command([proxy.nginx, '-e', str(proxy.root / 'error.log'), '-p', str(proxy.root), '-c', str(proxy.config), '-t'])
    proxy.process = subprocess.Popen([proxy.nginx, '-e', str(proxy.root / 'error.log'), '-p', str(proxy.root), '-c', str(proxy.config), '-g', 'daemon off;'], stdout=proxy.logs, stderr=proxy.logs, start_new_session=True)
    # Readiness uses a real TLS handshake, independent of arbitrary sleep.
    deadline = time.monotonic() + 5
    while True:
        try:
            if request(f, 'data', 'GET', '/v1/models', headers={'Authorization': 'Bearer ' + key})[0] == 200: break
        except OSError: pass
        assert time.monotonic() < deadline
        time.sleep(0.05)
    before_attempts, before_calls = ledger(f), f['provider'].calls
    body_started = time.monotonic()
    with socket.create_connection(('127.0.0.1', f['ports'][0]), timeout=4) as raw:
        with f['context'].wrap_socket(raw, server_hostname='localhost') as partial:
            partial.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: 128\r\n\r\n' + '{').encode())
            response = http.client.HTTPResponse(partial)
            try:
                response.begin(); assert response.status == 408; response.read()
            except http.client.RemoteDisconnected:
                # Streaming request-body timeout can close without a response.
                pass
    assert 0.7 < time.monotonic() - body_started < 3.5
    assert ledger(f) == before_attempts and f['provider'].calls == before_calls
    for prompt in ('tls-timeout', 'tls-preheader-timeout'):

        f['provider'].cancelled.clear(); before = f['provider'].calls
        started = time.monotonic()
        client = connection(f, 'data')
        try:
            client.request('POST', '/v1/responses', body=json.dumps({'model': MODEL, 'input': prompt, 'stream': True}), headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key})
            response = client.getresponse()
            if prompt == 'tls-preheader-timeout': assert response.status == 504
            else: assert response.status == 200
            try: body = response.read()
            except http.client.IncompleteRead as error: body = error.partial
            assert b'response.completed' not in body and time.monotonic() - started < 4
        finally: client.close()
        assert f['provider'].cancelled.wait(3)
        latest(f['root'] / 'state/core.sqlite', 'unknown')
        assert f['provider'].calls == before + 1, 'Proxy replayed timeout generation'
    print('PASS: injected Nginx partial-body timeout closes before dispatch; idle/pre-header read timeout closes upstream, keeps unknown and does not replay (delivery default remains 130s)')


def browser_checks(f, pin):
    result = subprocess.run(['node', str(REPO / 'web/scripts/tls-admin-ui.mjs')],
        input=json.dumps(dict(origin=f['origin'], credential=f['admin'],
            pin=pin, output=str(REPO / 'artifacts/tls-proxy-ui'))).encode(), capture_output=True, timeout=90)
    output = result.stdout + result.stderr
    assert len(output) < 65536 and all(value.encode() not in output for value in f['secrets'])
    print(output.decode(), end='')
    assert result.returncode == 0, 'Real HTTPS browser check failed; private diagnostics withheld'


def cleanup_failure_checks(args, root, tls, context):
    # A private-file failure after the listening socket was acquired must close it.
    early = root / 'early-failure'; early.mkdir(mode=0o700)
    acquired = []
    server_type = ThreadingHTTPServer
    def track_server(*arguments, **keywords):
        server = server_type(*arguments, **keywords); acquired.append(server)
        return server
    with patch.dict(fixture.__wrapped__.__globals__, ThreadingHTTPServer=track_server):
        with patch.object(Path, 'write_text', side_effect=OSError('Synthetic private-file failure')):
            try:
                with fixture(args, early, tls, context, 'http'): raise AssertionError('Setup failure was not injected')
            except OSError: pass
    assert len(acquired) == 1 and acquired[0].fileno() == -1
    # The Nginx master dies after readiness; its worker/group and every other
    # acquired owner must still be reaped despite close's non-zero assertion.
    late = root / 'nginx-failure'; late.mkdir(mode=0o700)
    value = None
    try:
        with fixture(args, late, tls, context, 'http') as value:
            value['proxy'].process.kill(); value['proxy'].process.wait(timeout=3)
    except AssertionError as error:
        assert str(error) == 'Nginx did not exit gracefully'
    else: raise AssertionError('Abnormal Nginx exit was not reported')
    assert value is not None
    assert value['process'].poll() == 0 and value['process'].stdout.closed
    assert value['proxy'].logs.closed and value['provider'].fileno() == -1
    assert not value['providerThread'].is_alive()
    for port in [*value['ports'], *value['gatewayPorts'].values()]:
        with socket.socket() as client:
            client.settimeout(1)
            assert client.connect_ex(('127.0.0.1', port)) != 0, 'Failed fixture retained a listener'
    print('PASS: injected private-file/Nginx-master failure reclaims provider, gateway, Nginx worker group and listeners')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--web', type=Path, default=REPO / 'web/dist')
    parser.add_argument('--nginx', default=shutil.which('nginx'))
    parser.add_argument('--openssl', default=shutil.which('openssl'))
    parser.add_argument('--browser', action='store_true')
    parser.add_argument('--cleanup-failure-only', action='store_true')
    args = parser.parse_args()
    assert args.nginx and args.openssl and (args.web / 'index.html').is_file(), 'Nginx, OpenSSL and built SPA are required'
    previous = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-tls-') as temporary:
            root = Path(temporary); tls = root / 'tls'; tls.mkdir(mode=0o700)
            context, pin = certificate(tls, args.openssl)
            if args.cleanup_failure_only:
                cleanup_failure_checks(args, root, tls, context)
                return
            for transport in ('http', 'websocket'):
                with fixture(args, root, tls, context, transport) as f:
                    key = token(f)
                    if transport == 'http':
                        trust_checks(f); admin_checks(f, key); limits_checks(f, key); stream_checks(f, key)
                        if args.browser: browser_checks(f, pin)
                        timeout_checks(f, key)
                    else: websocket_checks(f, key)
                    for path in (f['proxy'].root / 'process.log', f['proxy'].root / 'error.log'):
                        if path.exists():
                            contents = path.read_bytes()
                            assert all(secret.encode() not in contents for secret in f['secrets'])
                            assert str(root).encode() not in contents
                            assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}', contents) is None
            cleanup_failure_checks(args, root, tls, context)
            print('PASS: actual local TLS/Nginx stage; synthetic upstream only, no Desktop/subscription/M5 or target-host claim')
    finally: os.umask(previous)


if __name__ == '__main__':
    main()
