#!/usr/bin/env python3
"""Real-binary, loopback-only 16 MiB message boundary and per-turn HTTP fallback."""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sqlite3
import struct
import tempfile
import threading
import time

from verify_protocol import TOKEN, start, stop, dump_gateway_failure
from verify_websocket import dial, receive, send
from verify_json_order import SCHEMA, wire

LIMIT = 16 * 1024 * 1024
HEADERS = {'session-id': 'synthetic-large-session', 'x-codex-turn-state': 'synthetic-state'}


def frame(request, contract, native=False):
    value = dict(request)
    if native:
        value['stream'] = True
    if contract == 'codex-subscription':
        value['store'] = False
        value['stream'] = True
    else:
        value.pop('stream', None)
    value['type'] = 'response.create'
    if contract == 'codex-subscription':
        value['client_metadata'] = {'x-codex-turn-state': HEADERS['x-codex-turn-state']}
    return wire(value)


def sized(size, contract, streaming=False, native=False, image_count=1, **extra):
    value = {'model': 'synthetic-large', 'tools': [SCHEMA],
             'input': [{'role': 'user', 'content': [{'type': 'input_image',
                       'image_url': 'data:image/png;base64,synthetic'} for _ in range(image_count)]}],
             'instructions': '', 'stream': streaming, **extra}
    # Opaque synthetic image bytes are provider data; the fake does not decode an image codec.
    padding = size - len(frame(value, contract, native))
    images = value['input'][0]['content']
    for index, image in enumerate(images):
        image['image_url'] += 'x' * (padding // image_count + (index < padding % image_count))
    assert len(frame(value, contract, native)) == size
    return value


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def capture(self, body, path):
        with self.server.guard:
            self.server.calls.append((path, body, {k: self.headers.get(k) for k in HEADERS}))
            self.server.guard.notify_all()
            return len(self.server.calls)

    def event(self, index):
        response = dict(id=f'resp_synthetic_large_{index}', object='response', status='completed',
                        output=[], usage=dict(input_tokens=5, output_tokens=3, total_tokens=8, input_tokens_details=dict(cached_tokens=0)))
        return dict(type='response.completed', response=response)

    def do_POST(self):
        self.close_connection = True
        assert self.path == '/v1/responses'
        body = self.rfile.read(int(self.headers['Content-Length']))
        index = self.capture(body, 'http')
        request = json.loads(body)
        if self.server.mode == 'reject':
            self.send_response(413)
            self.send_header('Content-Length', '0')
            self.send_header('Retry-After', '30')  # must not encourage retry or cool account
            self.end_headers()
            return
        if self.server.mode == 'cancel':
            self.server.started.set()
            self.connection.settimeout(8)
            try:
                if self.connection.recv(1) == b'':
                    self.server.cancelled.set()
            except OSError:
                self.server.cancelled.set()
            return
        event = self.event(index)
        body = b'data: ' + wire(event) + b'\n\n' if request['stream'] else wire(event['response'])
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if request['stream'] else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.close_connection = True
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        for k, v in [('Upgrade', 'websocket'), ('Connection', 'Upgrade'), ('Sec-WebSocket-Accept', accept)]:
            self.send_header(k, v)
        self.end_headers()
        self.connection.settimeout(20)
        try:
            while True:
                opcode, body = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                if opcode == 9:
                    send(self.connection, body, opcode=10)
                    continue
                index = self.capture(body, 'websocket')
                # Emulates the provider message limit; gateway must never reach this branch.
                if len(body) > LIMIT:
                    self.server.oversized_ws += 1
                    send(self.connection, struct.pack('!H', 1009), opcode=8)
                    return
                if self.server.mode == 'close':
                    send(self.connection, struct.pack('!H', 1009), opcode=8)
                    return
                event = self.event(index)
                lane = json.loads(body).get('stream_id')
                if lane:
                    event['stream_id'] = lane
                send(self.connection, wire(event))
        except (OSError, EOFError):
            pass


def call_http(port, request):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    conn.request('POST', '/v1/responses', wire(request),
                 {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json', **HEADERS})
    response = conn.getresponse()
    status, headers, body = response.status, response.headers, response.read()
    conn.close()
    return status, headers, body


def native(peer, request):
    send(peer, wire({'type': 'response.create', **request}), masked=True, maximum_bytes=34 * 1024 * 1024)
    opcode, body = receive(peer)
    assert opcode == 1
    return json.loads(body)


def ledger(root, count):
    deadline = time.monotonic() + 6
    while True:
        with sqlite3.connect(root / 'state/core.sqlite') as db:
            rows = db.execute('SELECT state,outcome_json,usage_json FROM attempts ORDER BY rowid').fetchall()
            assert db.execute('SELECT COUNT(*) FROM account_health').fetchone()[0] == 0
            assert db.execute('SELECT COUNT(*) FROM account_model_health').fetchone()[0] == 0
        if len(rows) == count and all(s != 'intent' for s, _, _ in rows):
            return [(s, json.loads(o) if o else None, json.loads(u) if u else None) for s, o, u in rows]
        assert time.monotonic() < deadline, (count, [(s, o) for s, o, _ in rows])
        time.sleep(.02)


def error(body):
    value = json.loads(body)['error']
    assert value['code'] == 'conversation_too_large', value
    assert 'Start a new session or remove images' in value['message'], value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Condition()
    server.calls = []
    server.oversized_ws = 0
    server.started = threading.Event()
    server.cancelled = threading.Event()
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-ws-body-limit-') as temp:
            for contract in ('responses', 'codex-subscription'):
                root = Path(temp) / contract
                root.mkdir(mode=0o700)
                config = root / 'identity.json'
                config.write_text(json.dumps(dict(principal='synthetic-large', keyID='synthetic-key',
                    namespace='synthetic-large', identity='synthetic-account',
                    keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
                    models=[dict(id='synthetic-large', visionInput=True, inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
                    reservedMicros=1, upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',
                    upstreamTransport='websocket', upstreamContract=contract)))
                config.chmod(0o600)
                server.mode = 'ok'
                process, ports = start(str(args.binary.resolve()), config, root)
                count = 0
                try:
                    for route in ('json', 'sse', 'native'):
                        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
                            request = sized(size, contract, streaming=route != 'json', native=route == 'native',
                                            image_count=3 if route == 'sse' else 1)
                            before = len(server.calls)
                            if route == 'native':
                                with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
                                    result = native(peer, request)
                                if size > LIMIT:
                                    assert result['status'] == 413, result
                                    error(wire(result))
                                    assert len(server.calls) == before
                                    ledger(root, count)
                                    continue
                                assert result['type'] == 'response.completed', result
                            else:
                                status, headers, body = call_http(ports['data'], request)
                                assert status == 200, (contract, route, size, status, body[:500])
                                if route == 'sse':
                                    assert b'response.completed' in body and b'[DONE]' in body
                                else:
                                    assert json.loads(body)['status'] == 'completed'
                            count += 1
                            assert ledger(root, count)[-1][0] == 'settled'
                            path, raw, headers = server.calls[before]
                            expected_headers = dict(HEADERS)
                            if path == 'websocket' and contract == 'codex-subscription':
                                expected_headers['x-codex-turn-state'] = None  # projected into create metadata
                            assert headers == expected_headers, headers
                            if size <= LIMIT:
                                assert path == 'websocket' and raw == frame(request, contract, route == 'native')
                            else:
                                assert path == 'http'
                                expected = dict(request)
                                if contract == 'codex-subscription':
                                    expected['store'] = False
                                    expected['stream'] = True
                                assert raw == wire(expected).replace(b'/', b'\\/'), 'HTTP fallback changed key order or bytes'
                            assert wire(SCHEMA) in raw
                    # The fallback does not change subsequent transport selection.
                    status, _, _ = call_http(ports['data'], sized(1024, contract))
                    count += 1
                    assert status == 200 and server.calls[-1][0] == 'websocket'
                    ledger(root, count)
                    # Explicit HTTP refusal is deterministic, zero-cost, not unknown.
                    server.mode = 'reject'
                    for streaming in (False, True):
                        status, headers, body = call_http(ports['data'], sized(LIMIT + 1, contract, streaming=streaming))
                        assert status == 413 and headers.get('retry-after') is None, (status, body[:500])
                        error(body)
                        count += 1
                        state, outcome, usage = ledger(root, count)[-1]
                        assert state == 'settled' and outcome['failure'] == 'invalid_request', (state, outcome)
                        assert usage['completeness'] == 'complete' and usage['estimatedMicros'] == 0
                    server.mode = 'ok'
                    # Continuations remain on their native connection; oversized turn never dispatches.
                    with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
                        first = native(peer, sized(1024, contract, native=True))
                        previous = first['response']['id']
                        count += 1
                        ledger(root, count)
                        for extra in ({}, {'previous_response_id': previous}, {'generate': False}):
                            before = len(server.calls)
                            result = native(peer, sized(LIMIT + 100, contract, native=True, **extra))
                            assert result['status'] == 413, result
                            error(wire(result))
                            assert len(server.calls) == before
                            ledger(root, count)
                        result = native(peer, sized(1024, contract, native=True, previous_response_id=previous))
                        assert result['type'] == 'response.completed', result
                        count += 1
                        ledger(root, count)
                    # HTTP previous_response_id cannot silently become independent input.
                    status, _, body = call_http(ports['data'], sized(LIMIT + 1, contract, previous_response_id=previous))
                    assert status == 413, (status, body[:500])
                    error(body)
                    ledger(root, count)
                    # An actual below-limit 1009 close remains indeterminate, not our preflight error.
                    server.mode = 'close'
                    status, _, body = call_http(ports['data'], sized(1024, contract))
                    assert status == 502 and json.loads(body)['error']['code'] == 'execution_indeterminate'
                    count += 1
                    assert ledger(root, count)[-1][0] == 'unknown'
                    # Cancellation after HTTP dispatch retains unknown execution responsibility.
                    server.mode = 'cancel'
                    server.started.clear()
                    server.cancelled.clear()
                    peer = socket.create_connection(('127.0.0.1', ports['data']), timeout=30)
                    body = wire(sized(LIMIT + 1, contract))
                    session_headers = ''.join(f'{key}: {value}\r\n' for key, value in HEADERS.items())
                    peer.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n'
                                  f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\n'
                                  + session_headers + '\r\n').encode() + body)
                    assert server.started.wait(20)
                    peer.close()
                    assert server.cancelled.wait(8), 'Fallback upstream not cancelled'
                    count += 1
                    state, outcome, _ = ledger(root, count)[-1]
                    assert state == 'unknown' and outcome['failure'] == 'client_cancelled', (state, outcome)
                    # Existing ingress limit and error stay unchanged.
                    server.mode = 'ok'
                    conn = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=10)
                    conn.putrequest('POST', '/v1/responses')
                    conn.putheader('Authorization', 'Bearer ' + TOKEN)
                    conn.putheader('Content-Type', 'application/json')
                    conn.putheader('Content-Length', str(32 * 1024 * 1024 + 1))
                    conn.endheaders()
                    response = conn.getresponse()
                    status, body = response.status, response.read()
                    conn.close()
                    assert status == 413 and json.loads(body)['error']['code'] == 'request_too_large'
                    ledger(root, count)
                    process.terminate()
                    process.wait(10)
                    logs = process.stdout.read()
                    assert b'size_bucket=16_to_24_mib' in logs and b'path=http' in logs
                    assert b'path=reject_native' in logs
                    assert b'synthetic-state' not in logs and TOKEN.encode() not in logs
                except BaseException:
                    dump_gateway_failure(process)
                    raise
                finally:
                    stop(process)
                print(f'PASS: {contract}: exact WS boundaries, JSON/SSE/native, ordered fallback, continuation/warmup rejection, HTTP 413, cancellation and ledger', flush=True)
            assert server.oversized_ws == 0
    finally:
        server.shutdown()
        server.server_close()
        worker.join(5)


if __name__ == '__main__':
    main()
