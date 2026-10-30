#!/usr/bin/env python3
"""Desktop control contract against a byte-recording loopback provider; no external accounts."""
import argparse
import concurrent.futures
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
import time
from verify_protocol import start, stop
from verify_keys import ADMIN, create, update

PREFIX = '/backend-api/codex/'
ROUTES = [('POST', PREFIX + name) for name in (
    'alpha/search', 'memories/trace_summarize', 'realtime/calls', 'safety/arc',
    'thread/goal/get', 'thread/goal/set', 'thread/goal/clear')]
ROUTES += [('GET', PREFIX + 'thread/goal/get'), ('GET', PREFIX + 'agent-identities/jwks'),
           ('GET', '/backend-api/wham/agent-identities/jwks')]
SDP = b'v=0\r\na=synthetic-private-sdp-never-log\r\n'


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def do_GET(self): self.dispatch()
    def do_POST(self): self.dispatch()
    def dispatch(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with self.server.guard:
            self.server.calls.append((self.command, self.path, body, {k.lower(): v for k, v in self.headers.items()}))
        if body in (b'timeout', b'disconnect'):
            self.connection.settimeout(70)
            try:
                if self.connection.recv(1) == b'': self.server.cancelled.set()
            except OSError: pass
            return
        if body == b'hold': self.server.release.wait(65)
        status = int(body[4:]) if body.startswith(b'http') else 201
        reply = json.dumps({'error': {'code': 'synthetic_error', 'message': 'synthetic acct-private contact synthetic@example.invalid',
                                    'private': 'must-drop'}}).encode() if status >= 400 else b'\x00synthetic-response\xff'
        if status in (204, 304): reply = b''
        if body == b'oversize': reply = b'x' * (16 * 1024 * 1024 + 1)
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(reply)))
        self.send_header('ETag', 'synthetic-etag')
        self.send_header('Set-Cookie', 'synthetic=private')
        self.send_header('Connection', 'close, x-hop-secret')
        self.send_header('X-Hop-Secret', 'private')
        if status == 429: self.send_header('Retry-After', '30')
        self.end_headers()
        try: self.wfile.write(reply)
        except (BrokenPipeError, ConnectionResetError): pass


def wait_for(predicate):
    deadline = time.monotonic() + 6
    while not predicate() and time.monotonic() < deadline: time.sleep(.02)
    assert predicate(), 'Synthetic owner did not converge'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Lock(); server.calls = []
    server.release = threading.Event(); server.cancelled = threading.Event()
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-control-') as temporary:
            root = Path(temporary)
            admin = root / 'admin'; admin.write_text(ADMIN); admin.chmod(0o600)
            token = root / 'token'; token.write_text('synthetic-control-upstream-token'); token.chmod(0o600)
            config = root / 'identity.json'
            config.write_text(json.dumps(dict(managedKeys=True, reservedMicros=1, namespace='synthetic', identity='synthetic-account',
                upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1', upstreamTokenFile=str(token),
                models=[dict(id='synthetic-text', inputMicrosPerMillion=1, outputMicrosPerMillion=1)])))
            config.chmod(0o600)
            process, ports = start(str(args.binary.resolve()), config, root, admin_token_file=admin)
            try:
                key, secret = create(ports['admin'])
                def request(method='POST', path=PREFIX + 'alpha/search', body=b'synthetic\x00\xff', auth=secret, headers=None):
                    connection = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=70)
                    try:
                        sent = {'Content-Type': 'application/sdp', 'Cookie': 'synthetic-client-cookie',
                                'chatgpt-account-id': 'forged', **(headers or {})}
                        if auth is not None: sent['Authorization'] = 'Bearer ' + auth
                        connection.request(method, path, body, sent)
                        response = connection.getresponse()
                        return response.status, response.read(), {k.lower(): v for k, v in response.getheaders()}
                    finally: connection.close()
                for method, path in ROUTES:
                    query = '?x=%2f%2F&duplicate=1&duplicate=2&empty=&plus=a+b'
                    wire = SDP if path.endswith('realtime/calls') else b'synthetic\x00\xff'
                    before = len(server.calls)
                    status, body, headers = request(method, path + query, wire)
                    assert status == 201 and body == b'\x00synthetic-response\xff', (status, body[:200])
                    assert headers['content-type'] == 'application/octet-stream' and headers['etag'] == 'synthetic-etag'
                    assert 'set-cookie' not in headers and 'x-hop-secret' not in headers
                    assert len(server.calls) == before + 1
                    received_method, received_path, received_body, received_headers = server.calls[-1]
                    assert (received_method, received_path, received_body) == (method, path + query, wire)
                    assert received_headers['content-type'] == 'application/sdp'
                    assert received_headers['authorization'] == 'Bearer synthetic-control-upstream-token'
                    assert 'cookie' not in received_headers and 'chatgpt-account-id' not in received_headers
                for success in (200, 202, 204, 304):
                    assert request(body=f'http{success}'.encode())[0] == success
                assert request(headers={'Connection': 'accept, session_id', 'Accept': 'synthetic-private', 'session_id': 'synthetic-private'})[0] == 201
                assert 'accept' not in server.calls[-1][3] and 'session_id' not in server.calls[-1][3]
                before = len(server.calls)
                for method, path in ROUTES:
                    assert request('DELETE', path)[0] == 404
                    assert request(method, path + '/')[0] == 404
                for path in ('/v1/alpha/search', PREFIX + 'realtime', '/backend-api/transcribe', '/backend-api/files', '/api/codex/usage'):
                    assert request(path=path)[0] == 404
                assert request(auth=None)[0] == 401
                assert request(path=PREFIX + 'analytics-events/events')[0:2] == (202, b'{}')
                assert len(server.calls) == before
                for provider_status, expected in ((400, 400), (429, 429), (500, 502), (401, 502)):
                    status, body, headers = request(body=f'http{provider_status}'.encode())
                    assert status == expected, (status, body)
                    assert b'acct-private' not in body and b'synthetic@example.invalid' not in body and b'must-drop' not in body
                    if provider_status == 429: assert headers['retry-after'] == '30'
                before = len(server.calls)
                # Send only headers: the gateway must reject the declared size before buffering.
                connection = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=5)
                connection.putrequest('POST', PREFIX + 'alpha/search')
                connection.putheader('Authorization', 'Bearer ' + secret)
                connection.putheader('Content-Length', str(8 * 1024 * 1024 + 1))
                connection.endheaders()
                response = connection.getresponse(); assert response.status == 413; response.read(); connection.close()
                assert len(server.calls) == before
                assert request(body=b'x' * (8 * 1024 * 1024))[0] == 201
                assert request(body=b'oversize')[0] == 502
                before = len(server.calls)
                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    held = [pool.submit(request, body=b'hold') for _ in range(4)]
                    wait_for(lambda: len(server.calls) == before + 4)
                    status, body, headers = request()
                    assert status == 429 and b'control_capacity_exhausted' in body and headers['retry-after'] == '1'
                    assert len(server.calls) == before + 4
                    server.release.set()
                    assert all(task.result()[0] == 201 for task in held)
                assert request()[0] == 201
                # Two Keys fill all eight global slots; a third Key must reach the HTTP bulkhead.
                _, second_secret = create(ports['admin'])
                _, third_secret = create(ports['admin'])
                server.release.clear(); before = len(server.calls)
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    held = [pool.submit(request, body=b'hold', auth=secret if i < 4 else second_secret) for i in range(8)]
                    wait_for(lambda: len(server.calls) == before + 8)
                    status, body, headers = request(auth=third_secret)
                    assert status == 429 and b'control_capacity_exhausted' in body and headers['retry-after'] == '1'
                    assert len(server.calls) == before + 8
                    server.release.set()
                    assert all(task.result()[0] == 201 for task in held)
                assert request(auth=third_secret)[0] == 201
                # Chunked input cannot bypass the per-request limit or retain its body lease.
                before = len(server.calls)
                connection = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=10)
                connection.request('POST', PREFIX + 'alpha/search', iter([b'x' * (8 * 1024 * 1024), b'x']),
                    {'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/octet-stream'}, encode_chunked=True)
                response = connection.getresponse(); assert response.status == 413; response.read(); connection.close()
                assert len(server.calls) == before and request()[0] == 201
                # Downstream EOF cancels a body-waiting upstream before the 60-second deadline.
                server.cancelled.clear(); before = len(server.calls)
                sock = socket.create_connection(('127.0.0.1', ports['data']))
                sock.sendall((f'POST {PREFIX}alpha/search HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {secret}\r\nContent-Length: 10\r\n\r\n').encode() + b'disconnect')
                wait_for(lambda: len(server.calls) == before + 1); sock.close()
                assert server.cancelled.wait(6)
                server.cancelled.clear(); before = len(server.calls)
                began = time.monotonic()
                status, body, _ = request(body=b'timeout')
                assert status == 504 and b'execution_deadline_exceeded' in body, (status, body)
                assert 59 <= time.monotonic() - began < 68
                assert server.cancelled.wait(6) and len(server.calls) == before + 1
                before = len(server.calls)
                assert update(ports['admin'], key, enabled=False)[0] == 200
                assert request()[0] in (401, 403) and len(server.calls) == before
                with sqlite3.connect(root / 'state/core.sqlite') as db:
                    assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == 0
                process.terminate(); process.wait(10)
                output = process.stdout.read()
                for marker in (SDP.strip(), b'synthetic-private-sdp-never-log', b'synthetic-client-cookie', secret.encode(), token.read_bytes(), b'duplicate='):
                    assert marker not in output
                assert b'Control request ended' in output and process.returncode == 0
            finally:
                stop(process)
    finally:
        server.release.set(); server.shutdown(); server.server_close(); worker.join(5)
    print('PASS: all Desktop control routes preserve raw query/body/auth, reject unlisted methods and revoked Keys; local analytics; P27 errors; 8/16 MiB bounds; no-wait Key/global capacity and release; chunked bounds; 60s timeout and disconnect close upstream without replay; no intents or SDP/credential logs')


if __name__ == '__main__': main()
