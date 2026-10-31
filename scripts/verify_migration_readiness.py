#!/usr/bin/env python3
"""Migration contracts over loopback sockets only; synthetic metadata, no provider credentials."""
import argparse
import base64
import concurrent.futures
import ctypes
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sqlite3
import sys
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_keys import ADMIN, call
from verify_websocket import exact, send, receive

FINGERPRINT = {'user-agent': 'codex_cli_rs/9.10.0 (Synthetic OS; synthetic64) SyntheticTerminal/1',
               'originator': 'codex_cli_rs', 'version': '9.10.0'}
ADMIN_PORT = None

NATIVE = {'user-agent': 'Codex Desktop synthetic', 'originator': 'custom-native', 'version': 'original'}
FORBIDDEN = {'x-stainless-lang': 'typescript', 'x-openai-client-user-agent': 'private',
             'x-openai-actor-authorization': 'private', 'cookie': 'private',
             'proxy-authorization': 'private', 'chatgpt-account-id': 'forged'}


def events(scenario):
    response = dict(id='synthetic-' + scenario, status='completed', output=[],
                    usage=dict(input_tokens=2, output_tokens=1, input_tokens_details=dict(cached_tokens=0)))
    if scenario in ('error', 'failed', 'after-output', 'ambiguous'):
        error = dict(code='invalid_request_error' if scenario != 'ambiguous' else 'unrecognized_synthetic_error', message='Synthetic refusal')
        failure = dict(type='error', error=error)
        if scenario == 'failed':
            response.update(status='failed', usage=None, error=error)
            failure = dict(type='response.failed', response=response)
        if scenario == 'after-output':
            return [dict(type='response.created', response={**response, 'usage': None}),
                    dict(type='response.output_text.delta', delta='synthetic output'), failure]
        return [failure]
    return [dict(type='response.completed', response=response)]


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def record(self):
        headers = {k.lower(): v for k, v in self.headers.items()}
        assert all(name not in headers for name in FORBIDDEN)
        assert 'authorization' not in headers
        expected = NATIVE if headers.get('version') == 'original' else FINGERPRINT
        assert all(headers.get(k) == v for k, v in expected.items()), headers.keys()
        assert headers['x-codex-turn-state'] == 'synthetic-state'
        with self.server.guard:
            self.server.calls.append((self.path, headers))
    def reply(self, status, body, content_type='application/json', truncated=False):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body) + (50 if truncated else 0)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True
    def do_POST(self):
        self.record()
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        scenario = request.get('prompt', request.get('input', 'ok'))
        if scenario.startswith(('http', 'truncated')):
            status = int(scenario.removeprefix('http').removeprefix('truncated'))
            return self.reply(status, b'{"error":{"code":"synthetic"}}', truncated=scenario.startswith('truncated'))
        if scenario == 'disconnect': self.close_connection = True; return
        if scenario == 'timeout':
            time.sleep(5)
            self.close_connection = True
            return
        if scenario == 'hold':
            with self.server.guard: self.server.active += 1
            self.server.release.wait(8)
        if '/images/' in self.path:
            document = dict(data=[dict(b64_json=base64.b64encode(b'synthetic-image').decode())], usage=dict(input_tokens=2, output_tokens=1))
        elif self.path.endswith('/compact'):
            document = dict(object='response.compaction', id='synthetic-compact', output=[], usage=dict(input_tokens=2, output_tokens=1, input_tokens_details=dict(cached_tokens=0)))
        else: document = events(scenario)[-1].get('response', {})
        if request.get('stream'):
            body = b''.join(('data: ' + json.dumps(event) + '\n\n').encode() for event in events(scenario))
            return self.reply(200, body, 'text/event-stream')
        self.reply(200, json.dumps(document).encode())
    def do_GET(self):
        self.record()
        if self.server.handshake:
            return self.reply(self.server.handshake, b'{"error":"synthetic rejection"}', truncated=True)
        accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8: return
                request = json.loads(data)
                scenario = request.get('input', 'ok')
                if scenario == 'disconnect': return
                for event in events(scenario): send(self.connection, event)
        except (EOFError, OSError): pass
        finally: self.close_connection = True


def headers(native=False):
    return {'authorization': 'Bearer ' + TOKEN, 'content-type': 'application/json',
            'x-codex-turn-state': 'synthetic-state', **FORBIDDEN,
            **(NATIVE if native else {'user-agent': 'Claude Code synthetic', 'originator': 'magpie', 'version': 'private'})}


def request(port, scenario='ok', path='/v1/responses', native=False, stream=False):
    body = dict(model='synthetic-image', prompt=scenario) if '/images/' in path else dict(model='synthetic-text', input=scenario)
    if stream: body['stream'] = True
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        connection.request('POST', path, json.dumps(body), headers(native))
        response = connection.getresponse()
        return response.status, response.read()
    finally: connection.close()


def dial(port, native=False):
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    key = base64.b64encode(b'synthetic-ws-key!').decode()
    fields = {**headers(native), 'host': 'localhost', 'connection': 'Upgrade', 'upgrade': 'websocket',
              'sec-websocket-version': '13', 'sec-websocket-key': key}
    sock.sendall(('GET /v1/responses HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in fields.items()) + '\r\n').encode())
    head = bytearray()
    try:
        while not head.endswith(b'\r\n\r\n'): head.extend(exact(sock, 1))
        assert b' 101 ' in head
        return sock
    except BaseException: sock.close(); raise


def turn(sock, scenario='ok'):
    send(sock, dict(type='response.create', model='synthetic-text', input=scenario), masked=True)
    while True:
        opcode, body = receive(sock)
        assert opcode == 1
        event = json.loads(body)
        if event['type'] in ('error', 'response.failed', 'response.completed'): return event


def ledger(root, expected):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        with sqlite3.connect(root / 'state/core.sqlite') as db:
            row = db.execute('SELECT state,usage_json,outcome_json,id FROM attempts ORDER BY rowid DESC LIMIT 1').fetchone()
        if row and row[0] == expected:
            usage = json.loads(row[1]) if row[1] else None
            outcome = json.loads(row[2])
            if expected == 'settled':
                assert usage['providerRejectedBeforeOutput'] is True and usage['completeness'] == 'complete'
                assert all(usage[k] == 0 for k in ('inputTokens', 'outputTokens', 'cachedTokens', 'images', 'estimatedMicros'))
                assert outcome['kind'] == 'failed'
                hour = int(time.time()) // 3600 * 3600
                status, report = call(ADMIN_PORT, 'GET', f'/api/usage?start={hour}&end={hour + 3600}')
                assert status == 200
                record = next(item for item in report['rows'] if item['id'] == row[3])
                assert record['state'] == 'settled' and record['completeness'] == 'complete'
                assert int(record['metrics']['estimatedMicros']) == 0
                if record['model'] == 'synthetic-image':
                    assert usage['nativeImages'] and usage['imageInputTokens'] == usage['imageOutputTokens'] == 0
                    assert record['metrics']['inputTokens'] is None and int(record['metrics']['imageInputTokens']) == 0
            return usage
        time.sleep(.02)
    raise AssertionError('Refusal ledger failed to converge: ' + str(row))


def configuration(root, port, transport='http', limit=128):
    config = root / 'identity.json'
    config.write_text(json.dumps(dict(managedKeys=True,
        namespace='synthetic', identity='synthetic', reservedMicros=1, executionTimeoutSeconds=4,
        upstreamTransport=transport, upstreamBaseURL=f'http://127.0.0.1:{port}/v1', dataConnections=limit,
        clientFingerprint=dict(version='9.10.0', os='Synthetic OS', arch='synthetic64', terminal='SyntheticTerminal/1'),
        models=[dict(id='synthetic-text', inputMicrosPerMillion=1, outputMicrosPerMillion=1)],
        imageGeneration=dict(defaultModel='synthetic-image', models=[dict(id='synthetic-image', inputMicrosPerMillion=1, outputMicrosPerMillion=1)]))))
    config.chmod(0o600)
    return config


def launch(binary, config, root):
    global TOKEN, ADMIN_PORT
    admin = root / 'admin'; admin.write_text(ADMIN); admin.chmod(0o600)
    process, ports = start(binary, config, root, admin_token_file=admin)
    try:
        status, document = call(ports['admin'], 'POST', '/api/keys', dict(principal='synthetic',
            models=['synthetic-text'], imageGeneration=True, imageModels=['synthetic-image'],
            limits=dict(requests=10000, active=64, unresolved=100, budgetMicros=1000000, unresolvedMicros=1000000)))
        assert status == 201
        TOKEN = document['secret']
        ADMIN_PORT = ports['admin']
        return process, ports
    except BaseException: stop(process); raise


def sample(pid, label):
    if sys.platform == 'darwin':
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        task = ctypes.create_string_buffer(96)
        assert lib.proc_pidinfo(pid, 4, 0, task, len(task)) == 96
        rss = int.from_bytes(task.raw[8:16], sys.byteorder) // 1024
        files = ctypes.create_string_buffer(1024 * 1024)
        size = lib.proc_pidinfo(pid, 1, 0, files, len(files))
        assert size > 0
        descriptors = size // 8
    else:
        status = Path(f'/proc/{pid}/status').read_text().splitlines()
        rss = int(next(line for line in status if line.startswith('VmRSS:')).split()[1])
        descriptors = len(list(Path(f'/proc/{pid}/fd').iterdir()))
    result = dict(label=label, rssKiB=rss, descriptors=descriptors)
    print('RESOURCE ' + json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Lock(); server.calls = []; server.handshake = 0
    server.active = 0; server.release = threading.Event()
    thread = threading.Thread(target=server.serve_forever); thread.start()
    try:
        for transport in ('http', 'websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-migration-') as temporary:
                root = Path(temporary)
                process, ports = launch(str(args.binary.resolve()), configuration(root, server.server_port, transport), root)
                try:
                    for native in (False, True):
                        for path in ('/v1/responses', '/v1/responses/compact', '/v1/images/generations', '/backend-api/codex/alpha/search'):
                            result = request(ports['data'], path=path, native=native)
                            assert result[0] == 200, (transport, path, result)
                        if transport == 'websocket':
                            with dial(ports['data'], native) as sock: assert turn(sock)['type'] == 'response.completed'
                    if transport == 'http':
                        for path in ('/v1/responses', '/v1/responses/compact', '/v1/images/generations'):
                            for scenario in ('http400', 'http403', 'http429', 'truncated403'):
                                before = len(server.calls)
                                assert request(ports['data'], scenario, path=path)[0] in (400, 403, 429)
                                ledger(root, 'settled'); assert len(server.calls) == before + 1
                        for scenario in ('http500', 'disconnect', 'timeout'):
                            before = len(server.calls)
                            request(ports['data'], scenario)
                            ledger(root, 'unknown'); assert len(server.calls) == before + 1
                    for scenario in ('error', 'failed', 'after-output', 'ambiguous'):
                        request(ports['data'], scenario, stream=True)
                        ledger(root, 'settled' if scenario in ('error', 'failed') else 'unknown')
                    if transport == 'websocket':
                        for scenario in ('error', 'failed', 'after-output', 'ambiguous'):
                            with dial(ports['data']) as sock: turn(sock, scenario)
                            ledger(root, 'settled' if scenario in ('error', 'failed') else 'unknown')
                        for status in (400, 403, 429, 503):
                            server.handshake = status
                            request(ports['data'])
                            ledger(root, 'unknown' if status == 503 else 'settled')
                            with dial(ports['data']) as sock: turn(sock)
                            ledger(root, 'unknown' if status == 503 else 'settled')
                        server.handshake = 0
                finally: stop(process)
            print('PASS: migration fingerprint and refusal socket matrix ' + transport, flush=True)
        # Refused TCP connection retries before dispatch, while post-send failures above never replay.
        with tempfile.TemporaryDirectory(prefix='codexone-connect-retry-') as temporary:
            root = Path(temporary)
            reservation = socket.socket(); reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]; reservation.close()
            config = configuration(root, port)
            document = json.loads(config.read_text()); document['executionTimeoutSeconds'] = 8
            config.write_text(json.dumps(document))
            process, ports = launch(str(args.binary.resolve()), config, root)
            delayed = ThreadingHTTPServer(('127.0.0.1', port), Provider, bind_and_activate=False)
            delayed.guard = server.guard; delayed.calls = []; delayed.handshake = 0
            def listen_later():
                time.sleep(.5); delayed.server_bind(); delayed.server_activate(); delayed.serve_forever()
            delayed_thread = threading.Thread(target=listen_later); delayed_thread.start()
            try:
                assert request(ports['data'])[0] == 200
                assert len(delayed.calls) == 1
            finally:
                stop(process); delayed.shutdown(); delayed.server_close(); delayed_thread.join(3)
        print('PASS: connection failure retries before dispatch and sends once', flush=True)
        with tempfile.TemporaryDirectory(prefix='codexone-migration-capacity-') as temporary:
            root = Path(temporary)
            config = configuration(root, server.server_port, 'websocket', limit=72)
            document = json.loads(config.read_text()); document['executionTimeoutSeconds'] = 20
            config.write_text(json.dumps(document))
            process, ports = launch(str(args.binary.resolve()), config, root)
            sockets = []
            try:
                sample(process.pid, 'baseline')
                for _ in range(64):
                    sock = dial(ports['data']); sockets.append(sock)
                    assert turn(sock)['type'] == 'response.completed'
                sample(process.pid, '64_idle_ws_with_upstreams')
                # Switch to HTTP mode is unnecessary: compact always uses HTTP and holds an ordinary slot.
                with concurrent.futures.ThreadPoolExecutor(max_workers=12) as workers:
                    pending = [workers.submit(request, ports['data'], 'hold', '/v1/responses/compact') for _ in range(8)]
                    deadline = time.monotonic() + 5
                    while server.active < 8 and time.monotonic() < deadline: time.sleep(.01)
                    assert server.active == 8
                    sample(process.pid, '64_idle_ws_plus_8_active_http')
                    try:
                        status, _ = request(ports['data'])
                        assert status == 503, 'Ordinary connection limit was bypassed'
                    except (OSError, http.client.HTTPException): pass
                    # Control sockets have their own headroom and per-Key cap of four.
                    controls = [workers.submit(request, ports['data'], 'hold', '/backend-api/codex/alpha/search') for _ in range(4)]
                    deadline = time.monotonic() + 5
                    while server.active < 12 and time.monotonic() < deadline: time.sleep(.01)
                    assert server.active == 12
                    assert request(ports['data'], path='/backend-api/codex/alpha/search')[0] == 429
                    server.release.set()
                    assert all(f.result()[0] == 200 for f in pending + controls)
            finally:
                server.release.set()
                for sock in sockets: sock.close()
                stop(process)
        print('PASS: 64 WS + 8 HTTP accepted, ordinary cap enforced, control headroom returns 429', flush=True)
    finally:
        server.shutdown(); server.server_close(); thread.join(3)


if __name__ == '__main__': main()
