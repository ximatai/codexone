#!/usr/bin/env python3
"""Real-binary, loopback-only 16 MiB message boundary and per-turn HTTP fallback."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
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
from verify_upstream_zstd import Decoder
from verify_websocket import dial, receive, send
from verify_json_order import SCHEMA, wire

LIMIT = 16 * 1024 * 1024
ROUTING = 12 * 1024 * 1024
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
        if self.headers.get('Content-Encoding') == 'zstd':
            assert self.headers.get_all('Content-Encoding') == ['zstd']
            assert self.headers.get('Content-Length') is None
            assert self.headers.get('Transfer-Encoding') == 'chunked'
            decoder = Decoder()
            restored = bytearray()
            try:
                while True:
                    length = int(self.rfile.readline().strip(), 16)
                    if not length:
                        assert self.rfile.readline() == b'\r\n'
                        break
                    while length:
                        part = self.rfile.read(min(65536, length))
                        assert part
                        length -= len(part)
                        decoder.feed(part, restored.extend)
                        assert len(restored) <= 32 * 1024 * 1024
                    assert self.rfile.read(2) == b'\r\n'
                assert decoder.done
                body = bytes(restored)
            finally:
                decoder.close()
        else:
            assert self.headers.get('Content-Encoding') is None
            body = self.rfile.read(int(self.headers['Content-Length']))
        index = self.capture(body, 'http')
        request = json.loads(body)
        if self.server.mode in ('reject', 'close_reject', 'metadata_reject'):
            self.send_response(413)
            self.send_header('Content-Length', '0')
            self.send_header('Retry-After', '30')  # must not encourage retry or cool account
            self.end_headers()
            return
        if self.server.mode in ('cancel', 'close_cancel'):
            self.server.started.set()
            self.connection.settimeout(8)
            try:
                if self.connection.recv(1) == b'':
                    self.server.cancelled.set()
            except OSError:
                self.server.cancelled.set()
            return
        if self.server.mode == 'hold':
            assert self.server.release.wait(45), 'Measurement provider hold expired'
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
        self.connection.settimeout(120)
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
                if self.server.mode in ('multi_close', 'multi_close_queued'):
                    second_opcode, second_body = receive(self.connection, masked=True)
                    assert second_opcode == 1
                    self.capture(second_body, 'websocket')
                    if self.server.mode == 'multi_close_queued':
                        self.server.started.set()
                        assert self.server.release.wait(10), 'Queued-close provider hold expired'
                    send(self.connection, struct.pack('!H', 1009), opcode=8)
                    return
                if self.server.mode.startswith(('close', 'metadata', 'created', 'extension', 'other', 'drop')):
                    mode = self.server.mode
                    if mode.startswith('metadata'):
                        send(self.connection, wire(dict(type='rate_limits.updated', rate_limits=[])))
                    if mode.startswith('extension'):
                        event = dict(type='synthetic.future.started')
                        if mode == 'extension_response': event['type'] = 'response.future.started'
                        if mode == 'extension_identity': event['response_id'] = 'synthetic-unresolved'
                        send(self.connection, wire(event))
                    if mode == 'created':
                        send(self.connection, wire(dict(type='response.created', response=dict(
                            id=f'resp_synthetic_large_{index}', status='in_progress', output=[]))))
                    if not mode.endswith('drop'):
                        send(self.connection, struct.pack('!H', 1011 if mode.endswith('other') else 1009), opcode=8)
                    return
                if self.server.mode == 'hold':
                    assert self.server.release.wait(45), 'Synthetic WS hold expired'
                event = self.event(index)
                lane = json.loads(body).get('stream_id')
                if lane:
                    event['stream_id'] = lane
                send(self.connection, wire(event))
        except (OSError, EOFError):
            pass


def call_http(port, request, *, timeout=30):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
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


def configure(config, provider_port, contract):
    config.write_text(json.dumps(dict(principal='synthetic-large', keyID='synthetic-key',
        namespace='synthetic-large', identity='synthetic-account',
        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
        models=[dict(id='synthetic-large', visionInput=True, inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
        reservedMicros=1, upstreamBaseURL=f'http://127.0.0.1:{provider_port}/v1',
        upstreamTransport='websocket', upstreamContract=contract)))
    config.chmod(0o600)


def held_body_budgets(port, server, contract, process):
    """Parsing can drop raw bytes, but real socket requests still own their leases."""
    def wait_calls(expected):
        with server.guard:
            assert server.guard.wait_for(lambda: len(server.calls) == expected, timeout=30)

    def refused(size):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        try:
            connection.putrequest('POST', '/v1/responses')
            connection.putheader('Authorization', 'Bearer ' + TOKEN)
            connection.putheader('Content-Type', 'application/json')
            connection.putheader('Content-Length', str(size))
            connection.endheaders()
            response = connection.getresponse()
            assert response.status == 503
            assert json.loads(response.read())['error']['code'] == 'capacity_exhausted'
        finally:
            connection.close()

    # Serialize once before any native connection starts its first-create clock.
    native_payload = wire({'type':'response.create', **sized(9 * 1024 * 1024, contract, native=True)})
    server.release = threading.Event()
    server.mode = 'hold'
    # A held client must outlast the provider's bounded 45-second fixture hold.
    before = len(server.calls)
    with ThreadPoolExecutor(max_workers=2) as worker:
        holders = [worker.submit(call_http, port, sized(30 * 1024 * 1024, contract), timeout=60) for _ in range(2)]
        try:
            wait_calls(before + 2)
            refused(20 * 1024 * 1024)
            assert len(server.calls) == before + 2
        finally:
            server.release.set()
        for holder in holders: assert holder.result(timeout=30)[0] == 200
    server.release.clear()
    # A native WS can wait with only its frame header present, then continue after
    # the competing HTTP execution releases capacity; no full payload is queued.
    with ThreadPoolExecutor(max_workers=2) as worker:
        holders = [worker.submit(call_http, port, sized(32 * 1024 * 1024, contract), timeout=60) for _ in range(2)]
        wait_calls(before + 4)
        # Native Linux reports the process high-water mark, excluding fake-provider/client RSS.
        status_file = Path(f'/proc/{process.pid}/status')
        if status_file.exists():
            peak = next(int(line.split()[1]) for line in status_file.read_text().splitlines() if line.startswith('VmHWM:'))
            print('RESOURCE ' + json.dumps({'scenario':'two_maximum_bodies', 'peak_rss_kib':peak, 'budget_mib':64, 'contract':contract}), flush=True)
        try:
            with dial(port, headers=HEADERS, timeout=30) as peer:
                peer.sendall(b'\x81\xff' + struct.pack('!Q', len(native_payload)) + b'\0' * 4)
                time.sleep(.2)
                assert len(server.calls) == before + 4
                server.release.set()
                for holder in holders: assert holder.result(timeout=30)[0] == 200
                time.sleep(.5)
                peer.sendall(native_payload)
                opcode, body = receive(peer)
                assert opcode == 1 and json.loads(body)['type'] == 'response.completed'
                wait_calls(before + 5)
        finally:
            server.release.set()
    before = len(server.calls)
    server.release.clear()
    # Prepare large client bytes before starting the gateway's first-create timer.
    # Hold a 32 MiB HTTP execution plus two 9 MiB native turns; another 20 MiB
    # cannot fit. Opening each WS only when ready avoids idle clients expiring
    # while a slower Linux runner serializes the other peers' large fixtures.
    with ThreadPoolExecutor(max_workers=1) as worker:
        held = worker.submit(call_http, port, sized(32 * 1024 * 1024, contract), timeout=60)
        try:
            wait_calls(before + 1)
            with ExitStack() as stack:
                peers = []
                for _ in range(2):
                    peer = stack.enter_context(dial(port, headers=HEADERS, timeout=30))
                    peers.append(peer)
                    send(peer, native_payload, masked=True, maximum_bytes=10 * 1024 * 1024)
                    wait_calls(before + 1 + len(peers))
                refused(20 * 1024 * 1024)
                assert len(server.calls) == before + 3
                server.release.set()
                for peer in peers:
                    opcode, body = receive(peer)
                    assert opcode == 1 and json.loads(body)['type'] == 'response.completed'
            assert held.result(timeout=30)[0] == 200
        finally:
            server.release.set()
            server.mode = 'ok'
    # Completion/connection teardown returns capacity; a fresh large request dispatches.
    assert call_http(port, sized(31 * 1024 * 1024, contract))[0] == 200
    print('PASS: HTTP and first WS turns retain body budget after parsing; completion returns capacity', flush=True)
    return 9


def body_limit_diagnostics(binary, config, root, server, contract, failures_only):
    """Give log assertions a fresh process: the full matrix can exhaust the 16/min gate."""
    # Only four boundary events (two for --failures-only), even in one rate-limit window.
    root.mkdir(mode=0o700)
    process, ports = start(binary, config, root)
    logs = b''
    try:
        # Actual provider 1009 frames, below the proactive routing threshold.
        server.mode = 'close'
        before = len(server.calls)
        with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
            result = native(peer, sized(2048, contract, native=True))
        assert result['status'] == 413, result
        error(wire(result))
        assert [c[0] for c in server.calls[before:]] == ['websocket']
        ledger(root, 1)
        before = len(server.calls)
        status, _, body = call_http(ports['data'], sized(2048, contract))
        assert status == 200 and json.loads(body)['status'] == 'completed'
        assert [c[0] for c in server.calls[before:]] == ['websocket', 'http']
        ledger(root, 2)
        if not failures_only:
            server.mode = 'ok'
            before = len(server.calls)
            with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
                result = native(peer, sized(LIMIT + 1, contract, native=True))
            assert result['status'] == 413, result
            error(wire(result))
            assert len(server.calls) == before
            ledger(root, 2)
            before = len(server.calls)
            status, _, _ = call_http(ports['data'], sized(LIMIT + 1, contract))
            assert status == 200
            assert [c[0] for c in server.calls[before:]] == ['http']
            ledger(root, 3)
        process.terminate()
        process.wait(10)
        logs = process.stdout.read()
        boundaries = [line for line in logs.splitlines() if b'Request body size boundary' in line]
        # Match fields on the same event, rather than unrelated entries in the full log.
        assert any(b'path=reject_native_1009 ' in line and b'upstream_ws_close_code=1009' in line
                   and b'size_bucket=at_most_16_mib' in line for line in boundaries)
        assert any(b'path=http_1009 ' in line and b'upstream_ws_close_code=1009' in line
                   and b'size_bucket=at_most_16_mib' in line for line in boundaries)
        if not failures_only:
            assert any(b'path=reject_native ' in line and b'size_bucket=16_to_24_mib' in line
                       for line in boundaries)
            assert any(b'path=http ' in line and b'size_bucket=16_to_24_mib' in line
                       for line in boundaries)
        assert b'synthetic-state' not in logs and TOKEN.encode() not in logs
    except BaseException:
        dump_gateway_failure(process, output=logs)
        raise
    finally:
        stop(process)
        server.mode = 'ok'
    print(f'PASS: {contract}: isolated real 1009/native/HTTP body-limit diagnostics', flush=True)


def verify_small_body_budget(port, server, contract):
    """Known-size ordinary bodies hold bounded reservations even before admission."""
    before = len(server.calls)
    with ExitStack() as stack:
        # Park headers with a tiny prefix. This checks reservations without filling
        # memory or waiting for any provider execution.
        for _ in range(9):
            sock = stack.enter_context(socket.create_connection(('127.0.0.1', port), timeout=8))
            header = (f'POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                      f'Authorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\n'
                      f'Content-Length: {8 * 1024 * 1024}\r\n\r\n').encode()
            sock.sendall(header + b'{')
        time.sleep(.3)
        with ThreadPoolExecutor(max_workers=1) as worker, dial(port, headers=HEADERS, timeout=9) as peer:
            http_result = worker.submit(call_http, port, sized(1024, contract))
            peer.sendall(b'\x81\xfe' + struct.pack('!H', 1024) + b'\0' * 4)
            status, _, body = http_result.result(timeout=8)
            assert status == 503 and json.loads(body)['error']['code'] == 'capacity_exhausted', status
            opcode, body = receive(peer)
            assert opcode == 1, opcode
            event = json.loads(body)
            assert event['status'] == 503 and event['error']['code'] == 'capacity_exhausted', event
        assert len(server.calls) == before, 'Incomplete bodies or capacity waits dispatched upstream'
    # A fresh ordinary and a fresh large body both become serviceable after closure.
    assert call_http(port, sized(1024, contract))[0] == 200
    assert call_http(port, sized(32 * 1024 * 1024, contract))[0] == 200
    assert len(server.calls) == before + 2
    print(f'PASS: {contract}: ordinary HTTP/WS reservations are bounded before admission; closure reclaims capacity', flush=True)
    return 2


def verify_lane_close(port, server, root, contract, count, repetitions=12):
    for iteration in range(repetitions):
        queued = iteration >= repetitions - 4
        server.mode = 'multi_close_queued' if queued else 'multi_close'
        server.started.clear()
        server.release.clear()
        before = len(server.calls)
        with dial(port, headers=HEADERS, timeout=30) as peer:
            for lane in ('first', 'second'):
                send(peer, {**sized(1024, contract, native=True), 'type':'response.create', 'stream_id':lane}, masked=True)
            if queued:
                assert server.started.wait(5), 'Provider did not receive both lanes'
                for _ in range(3):
                    send(peer, {**sized(1024, contract, native=True), 'type':'response.create', 'stream_id':'first'}, masked=True)
                server.release.set()
            ended = set()
            while len(ended) < 2:
                opcode, data = receive(peer)
                assert opcode == 1, (contract, iteration, 'closed before all lane errors', sorted(ended),
                                     struct.unpack('!H', data[:2])[0] if opcode == 8 and len(data) >= 2 else opcode)
                event = json.loads(data)
                assert event['type'] == 'error' and event['status'] == 502, event
                assert event['stream_id'] not in ended, event
                ended.add(event['stream_id'])
            assert ended == {'first', 'second'}
            opcode, data = receive(peer)
            assert opcode == 8 and data[:2] == struct.pack('!H', 1000), (opcode, len(data))
        assert len(server.calls) == before + 2
        count += 2
        assert all(row[0] == 'unknown' and row[2] is None for row in ledger(root, count)[-2:])
    print('PASS: ' + contract + ': two-lane close drains both errors before connection close; unknown retained')
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--smoke', action='store_true', help='Keep representative wire boundaries and replay/cancellation checks')
    modes.add_argument('--small-body-only', action='store_true', help='Verify ordinary HTTP/WS aggregate body reservations')
    modes.add_argument('--lane-close-only', action='store_true', help='Repeat the small two-lane connection-close regression only')
    modes.add_argument('--failures-only', action='store_true', help='Run below-threshold close/fallback matrix only')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.guard = threading.Condition()
    server.calls = []
    server.oversized_ws = 0
    server.started = threading.Event()
    server.release = threading.Event()
    server.cancelled = threading.Event()
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-ws-body-limit-') as temp:
            for contract in ('responses', 'codex-subscription'):
                root = Path(temp) / contract
                root.mkdir(mode=0o700)
                config = root / 'identity.json'
                configure(config, server.server_port, contract)
                if not (args.small_body_only or args.smoke):
                    body_limit_diagnostics(str(args.binary.resolve()), config, root / 'diagnostics',
                                           server, contract, args.failures_only)
                server.mode = 'ok'
                process, ports = start(str(args.binary.resolve()), config, root)
                count = 0
                try:
                    if args.small_body_only:
                        count += verify_small_body_budget(ports['data'], server, contract)
                        ledger(root, count)
                        continue
                    if args.lane_close_only:
                        verify_lane_close(ports['data'], server, root, contract, count)
                        continue
                    if not args.failures_only:
                        count += verify_small_body_budget(ports['data'], server, contract)
                        if not args.smoke:
                            count += held_body_budgets(ports['data'], server, contract, process)
                        ledger(root, count)
                        for route in ('json', 'sse', 'native'):
                            sizes = {
                                'json': (ROUTING, ROUTING + 1),
                                'sse': (ROUTING + 1,),
                                'native': (ROUTING,),
                            }[route] if args.smoke else (ROUTING - 1, ROUTING, ROUTING + 1, LIMIT - 1, LIMIT, LIMIT + 1)
                            for size in sizes:
                                request = sized(size, contract, streaming=route != 'json', native=route == 'native',
                                                image_count=3 if route == 'sse' else 1)
                                before = len(server.calls)
                                if route == 'native':
                                    with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
                                        result = native(peer, request)
                                    if size > ROUTING:
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
                                if size <= ROUTING:
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
                        for streaming in ((False,) if args.smoke else (False, True)):
                            status, headers, body = call_http(ports['data'], sized(ROUTING + 1 if args.smoke else LIMIT + 1, contract, streaming=streaming))
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
                            continuation = {'previous_response_id': previous}
                            for extra in ((continuation,) if args.smoke else ({}, continuation, {'generate': False})):
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
                    # Both dispatched lanes retain unknown and must each deliver their error.
                    count = verify_lane_close(ports['data'], server, root, contract, count, repetitions=1 if args.smoke else 12)
                    # Real below-threshold refusals: exactly one HTTP replay, same bytes/state.
                    for mode in ('close', 'metadata', 'close_reject', 'metadata_reject'):
                        server.mode = mode
                        for streaming in (False, True):
                            request = sized(9 * 1024 * 1024 if not args.smoke and mode == "close" and contract == "codex-subscription" and not streaming else 2048, contract, streaming=streaming)
                            before = len(server.calls)
                            status, headers, body = call_http(ports['data'], request)
                            assert status == (413 if mode.endswith('reject') else 200), (mode, status, body)
                            calls = server.calls[before:]
                            assert [c[0] for c in calls] == ['websocket', 'http'], calls
                            assert calls[0][1] == frame(request, contract)
                            expected = dict(request)
                            if contract == 'codex-subscription':
                                expected.update(store=False, stream=True)
                            assert calls[1][1] == wire(expected).replace(b'/', b'\\/')
                            assert calls[1][2] == HEADERS
                            count += 1
                            state, outcome, usage = ledger(root, count)[-1]
                            assert state == 'settled', (state, outcome)
                            if status == 413:
                                error(body)
                                assert headers.get('retry-after') is None
                                assert outcome['failure'] == 'invalid_request'
                                assert usage['completeness'] == 'complete' and usage['inputTokens'] == usage['outputTokens'] == 0
                            else:
                                assert usage['inputTokens'] == 5 and usage['outputTokens'] == 3
                                assert b'rate_limits.updated' not in body
                    # Immediate small turns exercise the old-reader/new-session handoff.
                    # Do not poll the ledger between receiving 413 and sending the next create.
                    with dial(ports['data'], headers=HEADERS, timeout=30) as peer:
                        for mode in ('close', 'metadata') * (1 if args.smoke else 4):
                            server.mode = mode
                            before = len(server.calls)
                            result = native(peer, sized(2048, contract, native=True))
                            assert result['status'] == 413, result
                            error(wire(result))
                            server.mode = 'ok'
                            result = native(peer, sized(1024, contract, native=True))
                            assert result['type'] == 'response.completed', result
                            previous = result['response']['id']
                            count += 2
                            rows = ledger(root, count)
                            state, outcome, usage = rows[-2]
                            assert state == 'settled' and outcome['failure'] == 'invalid_request'
                            assert usage['completeness'] == 'complete' and usage['inputTokens'] == usage['outputTokens'] == 0
                            assert rows[-1][0] == 'settled'
                            assert [c[0] for c in server.calls[before:]] == ['websocket', 'websocket']
                    # A valid HTTP continuation can reach WS, but must never replay on HTTP.
                    if contract == 'responses':
                        server.mode = 'close'
                        before = len(server.calls)
                        status, _, body = call_http(ports['data'], sized(2048, contract, previous_response_id=previous))
                        assert status == 413, (status, body)
                        error(body)
                        assert [c[0] for c in server.calls[before:]] == ['websocket']
                        count += 1
                        state, outcome, usage = ledger(root, count)[-1]
                        assert state == 'settled' and outcome['failure'] == 'invalid_request'
                        assert usage['inputTokens'] == usage['outputTokens'] == 0
                    # Lifecycle, other close codes, and EOF keep indeterminate behavior, no replay.
                    for mode in ('created', 'extension', 'extension_response', 'extension_identity', 'other', 'drop'):
                        server.mode = mode
                        before = len(server.calls)
                        status, _, body = call_http(ports['data'], sized(1024, contract))
                        assert status == 502 and json.loads(body)['error']['code'] == 'execution_indeterminate', (mode, status, body)
                        assert [c[0] for c in server.calls[before:]] == ['websocket']
                        count += 1
                        assert ledger(root, count)[-1][0] == 'unknown'
                    # Metadata before any non-1009 close retains existing SSE byte order/status.
                    for mode in ('metadata_other', 'metadata_drop'):
                        server.mode = mode
                        before = len(server.calls)
                        status, _, body = call_http(ports['data'], sized(1024, contract, streaming=True))
                        assert status == 200, (mode, status, body)
                        assert body.index(b'rate_limits.updated') < body.index(b'event: error')
                        assert b'execution_indeterminate' in body
                        assert [c[0] for c in server.calls[before:]] == ['websocket']
                        count += 1
                        assert ledger(root, count)[-1][0] == 'unknown'
                    # Cancellation after HTTP dispatch retains unknown execution responsibility.
                    server.mode = 'close_cancel'
                    before = len(server.calls)
                    server.started.clear()
                    server.cancelled.clear()
                    peer = socket.create_connection(('127.0.0.1', ports['data']), timeout=30)
                    body = wire(sized(2048, contract))
                    session_headers = ''.join(f'{key}: {value}\r\n' for key, value in HEADERS.items())
                    peer.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n'
                                  f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\n'
                                  + session_headers + '\r\n').encode() + body)
                    assert server.started.wait(20)
                    peer.close()
                    assert server.cancelled.wait(8), 'Fallback upstream not cancelled'
                    assert [c[0] for c in server.calls[before:]] == ['websocket', 'http']
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
                    assert b'synthetic-state' not in logs and TOKEN.encode() not in logs
                except BaseException:
                    dump_gateway_failure(process)
                    raise
                finally:
                    stop(process)
                print(f'PASS: {contract}: {"smoke" if args.smoke else "full"} WS boundaries, JSON/SSE/native, ordered fallback, continuation rejection, HTTP 413, early/metadata/lifecycle 1009, other close/EOF, native socket reuse, cancellation and ledger', flush=True)
            assert server.oversized_ws == 0
    finally:
        server.shutdown()
        server.server_close()
        worker.join(5)


if __name__ == '__main__':
    main()
