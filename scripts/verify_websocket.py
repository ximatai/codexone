#!/usr/bin/env python3
"""Bounded RFC6455 socket fixtures. No external account, client settings, or dependencies."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import tempfile
import threading
import time
import argparse
from verify_protocol import TOKEN, connect, start, stop, latest


def exact(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError()
        data.extend(part)
    return bytes(data)


def send(sock, value, *, masked=False, opcode=1, fin=True):
    data = json.dumps(value).encode() if not isinstance(value, bytes) else value
    assert len(data) <= 524288
    header = bytes([(128 if fin else 0) | opcode])
    flag = 128 if masked else 0
    if len(data) < 126:
        header += bytes([flag | len(data)])
    elif len(data) < 65536:
        header += bytes([flag | 126]) + struct.pack('!H', len(data))
    else:
        header += bytes([flag | 127]) + struct.pack('!Q', len(data))
    if masked:
        key = os.urandom(4)
        header += key
        data = bytes(value ^ key[index % 4] for index, value in enumerate(data))
    sock.sendall(header + data)


def receive(sock, *, masked=False):
    first, second = exact(sock, 2)
    assert bool(second & 128) == masked
    length = second & 127
    if length == 126:
        length = struct.unpack('!H', exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack('!Q', exact(sock, 8))[0]
    assert length <= 524288
    key = exact(sock, 4) if masked else None
    data = exact(sock, length)
    if key:
        data = bytes(value ^ key[index % 4] for index, value in enumerate(data))
    return first & 15, data


def dial(port, path='/v1/responses', authorized=True):
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    auth = 'Authorization: Bearer ' + TOKEN + '\r\n' if authorized else ''
    sock.sendall((f'GET {path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n' + auth + '\r\n').encode())
    header = bytearray()
    while not header.endswith(b'\r\n\r\n'):
        header.extend(exact(sock, 1))
        assert len(header) < 16384
    assert b' 101 ' in header, header[:100]
    expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
    assert expected.lower() in header.lower()
    return sock


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def do_GET(self):
        assert self.path == '/v1/responses'
        assert self.headers.get('Authorization') is None
        assert self.headers.get('X-Synthetic-Secret') is None
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        with self.server.guard:
            self.server.connections += 1
            connection = self.server.connections
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                assert opcode == 1
                create = json.loads(data)
                assert create['type'] == 'response.create' and 'stream' not in create
                with self.server.guard:
                    self.server.calls += 1
                    index = self.server.calls
                if create['input'] == 'stall':
                    self.server.stalled.set()
                    self.connection.settimeout(6)
                    if self.connection.recv(1) == b'':
                        self.server.cancelled.set()
                    return
                if create['input'] == 'abrupt':
                    return
                previous = create.get('previous_response_id')
                if previous:
                    assert previous.startswith(f'resp_{connection}_'), 'Connection context was switched'
                response = {'id': f'resp_{connection}_{index}', 'status': 'completed', 'output': [],
                            'usage': {'input_tokens': 5, 'output_tokens': 3, 'input_tokens_details': {'cached_tokens': 0}}}
                send(self.connection, {'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'usage': None}})
                time.sleep(0.02)
                send(self.connection, {'type': 'response.completed', 'response': response})
                if create['input'] == 'duplicate-terminal':
                    send(self.connection, {'type': 'response.completed', 'response': response})
                if create['input'] == 'trailing-event':
                    send(self.connection, {'type': 'response.output_text.delta', 'delta': 'OLD_TURN_TRAILING_SYNTHETIC'})
                if create['input'] == 'terminal-eof':
                    return
        except (EOFError, ConnectionResetError, BrokenPipeError, TimeoutError):
            self.server.cancelled.set()
        finally:
            self.close_connection = True


def turn(sock, value):
    send(sock, {'type': 'response.create', **value}, masked=True)
    events = []
    while True:
        opcode, data = receive(sock)
        assert opcode == 1
        event = json.loads(data)
        events.append(event)
        if event['type'] in ('response.completed', 'error'):
            return events
        assert len(events) < 20


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.calls = provider.connections = 0
    provider.stalled = threading.Event()
    provider.cancelled = threading.Event()
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-ws-') as temporary:
            directory = Path(temporary)
            config = directory / 'identity.json'
            config.write_text(json.dumps({'principal': 'synthetic-principal', 'keyID': 'synthetic-key',
                'keySHA256': hashlib.sha256(TOKEN.encode()).hexdigest(), 'namespace': 'synthetic-provider',
                'identity': 'synthetic-account', 'reservedMicros': 10, 'executionTimeoutSeconds': 2,
                'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000}],
                'upstreamBaseURL': f'http://127.0.0.1:{provider.server_port}/v1', 'upstreamTransport': 'websocket'}))
            config.chmod(0o600)
            process, ports = start(str(args.binary.resolve()), config, directory)
            db = directory / 'state/core.sqlite'
            try:
                # A local handshake must not open a provider socket.
                with dial(ports['data']) as downstream:
                    time.sleep(0.05)
                    assert provider.connections == 0
                    send(downstream, b'synthetic-ping', masked=True, opcode=9)
                    assert receive(downstream) == (10, b'synthetic-ping')
                    request = json.dumps({'type': 'response.create', 'model': 'synthetic-text', 'input': 'first', 'store': False}).encode()
                    send(downstream, request[:20], masked=True, fin=False)
                    send(downstream, request[20:], masked=True, opcode=0)
                    first = json.loads(receive(downstream)[1])
                    completed = json.loads(receive(downstream)[1])
                    assert first['type'] == 'response.created' and completed['type'] == 'response.completed'
                    assert latest(db, 'settled')['inputTokens'] == 5
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'next', 'previous_response_id': completed['response']['id']})
                    assert events[-1]['type'] == 'response.completed' and provider.connections == 1
                    # Queue two turns while the first is still in progress; the default lane is FIFO.
                    for prompt in ('queued-first', 'queued-second'):
                        send(downstream, {'type': 'response.create', 'model': 'synthetic-text', 'input': prompt}, masked=True)
                    ids = []
                    for _ in range(4):
                        event = json.loads(receive(downstream)[1])
                        if event['type'] == 'response.completed':
                            ids.append(int(event['response']['id'].rsplit('_', 1)[1]))
                    assert len(ids) == 2 and ids[1] == ids[0] + 1
                for streaming in (False, True):
                    status, body = connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'bridge', 'stream': streaming})
                    assert status == 200 and b'completed' in body
                    assert latest(db, 'settled')['estimatedMicros'] == 8
                print('PASS: native handshake is local; masking/fragmentation/ping; same-socket continuation; HTTP JSON/SSE to WS bridges')
                with dial(ports['data'], '/backend-api/codex/responses') as downstream:
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'terminal-eof'})
                    assert events[-1]['type'] == 'response.completed'
                    assert latest(db, 'settled')['inputTokens'] == 5
                for prompt in ('duplicate-terminal', 'trailing-event'):
                    with sqlite3.connect(db) as connection:
                        before = connection.execute('SELECT count(*) FROM attempts WHERE state="settled"').fetchone()[0]
                    with dial(ports['data']) as downstream:
                        events = turn(downstream, {'model': 'synthetic-text', 'input': prompt})
                        assert events[-1]['type'] == 'response.completed'
                        time.sleep(0.1)
                        try:
                            events = turn(downstream, {'model': 'synthetic-text', 'input': 'new-turn'})
                            assert events[-1]['type'] == 'error'
                            assert 'OLD_TURN_TRAILING_SYNTHETIC' not in json.dumps(events)
                        except (EOFError, BrokenPipeError, ConnectionResetError):
                            pass
                    latest(db, 'settled')
                    with sqlite3.connect(db) as connection:
                        after = connection.execute('SELECT count(*) FROM attempts WHERE state="settled"').fetchone()[0]
                    assert after == before + 1, 'An old terminal settled a different turn'
                with dial(ports['data']) as downstream:
                    count = provider.calls
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'unknown-ref', 'previous_response_id': 'unknown-synthetic-response'})
                    assert events[-1]['error']['code'] == 'unknown_or_ambiguous_object'
                    assert events[-1]['error']['type'] == 'invalid_request_error'
                    assert provider.calls == count
                print('PASS: duplicate terminals and trailing events cannot cross turns or settle a new attempt; rejection errors preserve classification')
                status, body = connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'abrupt', 'stream': True})
                assert status in (200, 502) and b'completed' not in body
                assert latest(db, 'unknown') is None
                count = provider.calls
                with dial(ports['data']) as downstream:
                    send(downstream, {'type': 'response.cancel'}, masked=True)
                    try:
                        receive(downstream)
                    except (EOFError, ConnectionResetError):
                        pass
                assert provider.calls == count
                print('PASS: terminal plus provider EOF keeps evidence; abrupt close stays unknown; unsupported controls do not dispatch')
                provider.cancelled.clear()
                with dial(ports['data']) as downstream:
                    send(downstream, {'type': 'response.create', 'model': 'synthetic-text', 'input': 'stall'}, masked=True)
                    assert provider.stalled.wait(3)
                assert provider.cancelled.wait(4)
                latest(db, 'unknown')
                with sqlite3.connect(db) as connection:
                    connection.execute("CREATE TRIGGER fail_binding BEFORE INSERT ON bindings BEGIN SELECT RAISE(ABORT,'synthetic fault'); END")
                with dial(ports['data']) as downstream:
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'barrier-failure'})
                    assert events[-1]['type'] == 'error' and b'resp_' not in json.dumps(events).encode()
                # response.created failed before a terminal was read; intent remains unknown.
                latest(db, 'unknown')
                assert connect(ports['data'], 'GET', '/health/ready')[0] == 503
                print('PASS: queued default-lane turns preserve FIFO; persistent binding failure prevents ID exposure')
                # Include an accepted socket whose HTTP/upgrade head never completes at shutdown.
                pending = socket.create_connection(('127.0.0.1', ports['data']), timeout=5)
                pending.sendall(b'GET /v1/responses HTTP/1.1\r\n')
                process.terminate()
                assert process.wait(timeout=8) == 0
                assert pending.recv(1) == b''
                pending.close()
                output = process.stdout.read()
                assert TOKEN.encode() not in output and temporary.encode() not in output
                print('PASS: silent downstream close cancels provider; shutdown owns pending negotiations and releases sockets')
            finally:
                stop(process)
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=3)


if __name__ == '__main__':
    main()
