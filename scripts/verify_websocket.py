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


def send(sock, value, *, masked=False, opcode=1, fin=True, rsv1=False, maximum_bytes=524288):
    data = json.dumps(value).encode() if not isinstance(value, bytes) else value
    assert len(data) <= maximum_bytes
    header = bytes([(128 if fin else 0) | (64 if rsv1 else 0) | opcode])
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
    assert length <= (34603008 if masked else 8388608)
    key = exact(sock, 4) if masked else None
    data = exact(sock, length)
    if key:
        data = bytes(value ^ key[index % 4] for index, value in enumerate(data))
    return first & 15, data


def dial(port, path='/v1/responses', authorized=True, extension_offer=False, token=TOKEN, headers=None):
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    auth = 'Authorization: Bearer ' + token + '\r\n' if authorized else ''
    auth += ''.join(f'{name}: {value}\r\n' for name, value in (headers or {}).items())
    extensions = 'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n' if extension_offer else ''
    sock.sendall((f'GET {path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n' + auth + extensions + '\r\n').encode())
    header = bytearray()
    while not header.endswith(b'\r\n\r\n'):
        header.extend(exact(sock, 1))
        assert len(header) < 16384
    assert b' 101 ' in header, header[:100]
    expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
    assert expected.lower() in header.lower()
    assert b'sec-websocket-extensions:' not in header.lower()
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
        pending = None
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
                if create['input'] == 'close-gated':
                    self.server.close_ready.set()
                    assert self.server.close_release.wait(4)
                    send(self.connection, b'\x03\xe8', opcode=8)
                    return
                if create['input'] == 'abrupt':
                    return
                previous = create.get('previous_response_id')
                if previous:
                    assert previous.startswith(f'resp_{connection}_'), 'Connection context was switched'
                response = {'id': f'resp_{connection}_{index}', 'status': 'completed', 'output': [],
                            'usage': {'input_tokens': 5, 'output_tokens': 3, 'input_tokens_details': {'cached_tokens': 0}}}
                if create.get('generate') is False:
                    response['usage'] = None
                lane = {'stream_id': create['stream_id']} if 'stream_id' in create else {}
                if create['input'] == 'invalid-upstream-lane':
                    lane = {'stream_id': 'invalid lane'}
                send(self.connection, {'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'usage': None}, **lane})
                if create['input'] in ('multi-slow', 'mixed-known'):
                    pending = (lane, response)
                    continue
                if create['input'] == 'mixed-unknown':
                    assert pending is not None
                    for item_index in range(3):
                        item = {'id': f'msg_{connection}_{index}_{item_index}', 'type': 'message', 'role': 'assistant',
                                'content': [{'type': 'output_text', 'text': 'synthetic queue', 'annotations': []}]}
                        send(self.connection, {'type': 'response.output_item.added', 'item': item, **pending[0]})
                    send(self.connection, {'type': 'response.completed', 'response': pending[1], **pending[0]})
                    return
                time.sleep(0.02)
                send(self.connection, {'type': 'response.completed', 'response': response, **lane})
                if create['input'] == 'multi-fast' and pending:
                    time.sleep(0.1)
                    send(self.connection, {'type': 'response.completed', 'response': pending[1], **pending[0]})
                    pending = None
                if create['input'] == 'duplicate-terminal':
                    send(self.connection, {'type': 'response.completed', 'response': response})
                if create['input'] == 'trailing-event':
                    send(self.connection, {'type': 'response.output_text.delta', 'delta': 'OLD_TURN_TRAILING_SYNTHETIC'})
                if create['input'] == 'idle-close':
                    time.sleep(.05)
                    send(self.connection, b'\x03\xe8', opcode=8)
                    return
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
    provider.close_ready = threading.Event()
    provider.close_release = threading.Event()
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
                with dial(ports['data'], extension_offer=True) as downstream:
                    send(downstream, {'type': 'response.create', 'model': 'synthetic-text', 'input': 'forbidden compression'}, masked=True, rsv1=True)
                    try:
                        assert receive(downstream)[0] == 8
                    except (EOFError, ConnectionResetError):
                        pass
                assert provider.connections == 0
                with sqlite3.connect(db) as connection:
                    assert connection.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == 0
                print('PASS: extension offer is declined without negotiation; unnegotiated RSV frames close before dispatch')
                # A local handshake must not open a provider socket.
                with dial(ports['data'], extension_offer=True) as downstream:
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
                with dial(ports['data']) as downstream:
                    send(downstream, {'type': 'response.create', 'stream_id': 'lane_a', 'model': 'synthetic-text', 'input': 'multi-slow'}, masked=True)
                    first = json.loads(receive(downstream)[1])
                    assert first['stream_id'] == 'lane_a' and first['type'] == 'response.created'
                    send(downstream, {'type': 'response.create', 'stream_id': 'lane_a', 'model': 'synthetic-text', 'input': 'queued-next'}, masked=True)
                    send(downstream, {'type': 'response.create', 'stream_id': 'lane_b', 'model': 'synthetic-text', 'input': 'multi-fast'}, masked=True)
                    completed = []
                    for _ in range(5):
                        event = json.loads(receive(downstream)[1])
                        assert event['type'] != 'error', event
                        if event['type'] == 'response.completed':
                            completed.append((event['stream_id'], event['response']['id']))
                    assert [lane for lane, _ in completed] == ['lane_b', 'lane_a', 'lane_a']
                    assert len(set(response for _, response in completed)) == 3
                print('PASS: a blocked lane permits another lane to complete; same-lane queued turns stay FIFO with response ownership')
                for _ in range(3):
                    with sqlite3.connect(db) as connection:
                        mark = connection.execute('SELECT coalesce(max(rowid),0) FROM attempts').fetchone()[0]
                    with dial(ports['data']) as downstream:
                        send(downstream, {'type': 'response.create', 'stream_id': 'known', 'model': 'synthetic-text', 'input': 'mixed-known'}, masked=True)
                        assert json.loads(receive(downstream)[1])['type'] == 'response.created'
                        send(downstream, {'type': 'response.create', 'stream_id': 'unknown', 'model': 'synthetic-text', 'input': 'mixed-unknown'}, masked=True)
                        try:
                            for _ in range(12):
                                opcode, _data = receive(downstream)
                                if opcode == 8:
                                    break
                        except (EOFError, ConnectionResetError):
                            pass
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        with sqlite3.connect(db) as connection:
                            rows = connection.execute('SELECT state,usage_json FROM attempts WHERE rowid>?', (mark,)).fetchall()
                        if len(rows) == 2 and all(state != 'intent' for state, _ in rows):
                            break
                        time.sleep(0.02)
                    assert sorted(state for state, _ in rows) == ['settled', 'unknown'], rows
                    for state, usage in rows:
                        if state == 'settled':
                            assert json.loads(usage)['inputTokens'] == 5
                        else:
                            assert usage is None
                with dial(ports['data']) as downstream:
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'invalid-upstream-lane'})
                    assert events[-1]['error']['code'] == 'invalid_upstream_lane'
                    assert events[-1]['error']['type'] == 'server_error'
                print('PASS: one lane EOF cannot erase another queued terminal; malformed provider lane is a server error')
                with dial(ports['data']) as downstream:
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'warmup', 'generate': False})
                    assert events[-1]['type'] == 'response.completed' and events[-1]['response']['output'] == []
                    assert latest(db, 'unknown') is None
                    with sqlite3.connect(db) as connection:
                        mode = json.loads(connection.execute('SELECT admission_json FROM attempts ORDER BY rowid DESC LIMIT 1').fetchone()[0])['mode']
                    assert mode == 'warmup'
                    previous = events[-1]['response']['id']
                    events = turn(downstream, {'model': 'synthetic-text', 'input': 'post-warmup', 'previous_response_id': previous})
                    assert events[-1]['type'] == 'response.completed'
                    assert latest(db, 'settled')['inputTokens'] == 5
                print('PASS: WS generate:false has its own persisted mode; absent usage stays unknown; warmup response can continue on the same socket')
                for streaming in (False, True):
                    status, body = connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'bridge', 'stream': streaming})
                    assert status == 200 and b'completed' in body
                    assert latest(db, 'settled')['estimatedMicros'] == 8
                print('PASS: native handshake is local; masking/fragmentation/ping; same-socket continuation; HTTP JSON/SSE to WS bridges')
                for prompt in ('idle-close', 'terminal-eof'):
                    with sqlite3.connect(db) as connection:
                        before = connection.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
                    count = provider.calls
                    with sqlite3.connect(db) as connection:
                        rejected_before = connection.execute('SELECT COUNT(*) FROM request_diagnostics').fetchone()[0]
                        unknown_before = connection.execute('SELECT COUNT(*) FROM attempts WHERE state="unknown"').fetchone()[0]
                    with dial(ports['data']) as downstream:
                        assert turn(downstream, {'model': 'synthetic-text', 'input': prompt})[-1]['type'] == 'response.completed'
                        # A create sent after EOF but before consuming the close cannot dispatch.
                        time.sleep(.15)
                        send(downstream, {'type': 'response.create', 'model': 'synthetic-text', 'input': 'late'}, masked=True)
                        assert receive(downstream) == (8, b'\x03\xe8')
                    with sqlite3.connect(db) as connection:
                        assert connection.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == before + 1
                        assert connection.execute('SELECT COUNT(*) FROM attempts WHERE state="unknown"').fetchone()[0] == unknown_before
                        assert connection.execute('SELECT COUNT(*) FROM request_diagnostics').fetchone()[0] == rejected_before
                    assert provider.calls == count + 1
                    with dial(ports['data']) as downstream:
                        assert turn(downstream, {'model': 'synthetic-text', 'input': 'fresh'})[-1]['type'] == 'response.completed'
                for multi in (False, True):
                    provider.close_ready.clear(); provider.close_release.clear()
                    with sqlite3.connect(db) as connection:
                        mark = connection.execute('SELECT coalesce(max(rowid),0) FROM attempts').fetchone()[0]
                    count = provider.calls
                    with dial(ports['data']) as downstream:
                        if multi:
                            assert turn(downstream, {'stream_id': 'idle', 'model': 'synthetic-text', 'input': 'first'})[-1]['type'] == 'response.completed'
                        create = {'type': 'response.create', 'stream_id': 'busy', 'model': 'synthetic-text', 'input': 'close-gated'}
                        send(downstream, create, masked=True)
                        assert provider.close_ready.wait(3)
                        # This is owned by the same-lane queue, before upstream EOF.
                        send(downstream, {**create, 'input': 'queued'}, masked=True)
                        time.sleep(.05)
                        provider.close_release.set()
                        # Cross EOF/consumer cancellation while the connection owner is unwinding.
                        for _ in range(2):
                            send(downstream, {**create, 'input': 'closing-race'}, masked=True)
                        for _ in range(8):
                            opcode, data = receive(downstream)
                            if opcode == 8:
                                assert data == b'\x03\xe8'
                                break
                        else: raise AssertionError('No normal close after active EOF')
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            with sqlite3.connect(db) as connection:
                                rows = connection.execute('SELECT state FROM attempts WHERE rowid>?', (mark,)).fetchall()
                            if sorted(row[0] for row in rows) == (['settled', 'unknown'] if multi else ['unknown']):
                                break
                            time.sleep(.02)
                        else: raise AssertionError(rows)
                    assert provider.calls == count + (2 if multi else 1)
                print('PASS: idle close frame/TCP EOF sends 1000; fresh connection works; queued/late creates never dispatch; active/multi-lane EOF keeps unknown without replay')
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
                        # Identified late events are delivered outside attempts; unidentified output stays dropped.
                        if prompt == 'duplicate-terminal':
                            assert json.loads(receive(downstream)[1])['type'] == 'response.completed'
                        events = turn(downstream, {'model': 'synthetic-text', 'input': 'new-turn'})
                        assert events[-1]['type'] == 'response.completed', events
                        assert 'OLD_TURN_TRAILING_SYNTHETIC' not in json.dumps(events)
                    latest(db, 'settled')
                    with sqlite3.connect(db) as connection:
                        after = connection.execute('SELECT count(*) FROM attempts WHERE state="settled"').fetchone()[0]
                    assert after == before + 2, 'An old terminal settled a different turn'
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
                try:
                    assert pending.recv(1) == b''
                except ConnectionResetError:
                    # A close with an unread partial HTTP head may surface as TCP RST.
                    pass
                finally:
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
