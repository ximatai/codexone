#!/usr/bin/env python3
"""Explicit synthetic Desktop preflight: persistent sockets and maximum image envelopes.

This is a gateway/socket test, never a Desktop or subscription compatibility claim.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import re
import socket
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from verify_protocol import start, stop, latest
from verify_keys import ADMIN, LIMITS, call
from verify_websocket import dial, exact

MIB = 1024 * 1024
MODEL = 'synthetic-host'


def png(size, fill=b'x'):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    head = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 1024, 1024, 8, 6, 0, 0, 0))
    pixels = zlib.compress((b'\0' + b'\x20\x40\x60\xff' * 1024) * 1024)
    body = head + chunk(b'IDAT', pixels)
    # Valid ancillary padding gives exact container byte boundaries without user images.
    result = body + chunk(b'tEXt', b'boundary\0' + fill * (size - len(body) - 12 - 12 - 9)) + chunk(b'IEND', b'')
    assert len(result) == size
    return result


def frame(sock, value, masked=False):
    data = json.dumps(value, separators=(',', ':')).encode() if not isinstance(value, bytes) else value
    assert len(data) <= 8 * MIB
    flag = 128 if masked else 0
    header = b'\x81' + (bytes([flag | len(data)]) if len(data) < 126 else bytes([flag | 126]) + struct.pack('!H', len(data)) if len(data) < 65536 else bytes([flag | 127]) + struct.pack('!Q', len(data)))
    if masked:
        mask = b'\x15\x28\x31\x42'
        header += mask
        data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
    sock.sendall(header + data)


def read_frame(sock, masked=False):
    first, second = exact(sock, 2)
    assert first & 128 and bool(second & 128) == masked
    size = second & 127
    if size == 126: size = struct.unpack('!H', exact(sock, 2))[0]
    elif size == 127: size = struct.unpack('!Q', exact(sock, 8))[0]
    assert size <= (9 if masked else 8) * MIB
    mask = exact(sock, 4) if masked else None
    data = exact(sock, size)
    if mask: data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
    return first & 15, data


def marker(request):
    value = request.get('input')
    if isinstance(value, str): return value
    for item in value or []:
        for part in item.get('content', []) if isinstance(item, dict) and isinstance(item.get('content'), list) else []:
            if isinstance(part, dict) and part.get('type') == 'input_text': return part['text']
    raise AssertionError('Missing synthetic invocation')


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def failure(self, kind):
        with self.server.guard:
            self.server.failures += 1
            if len(self.server.failure_kinds) < 8: self.server.failure_kinds.append(kind)
    def handle(self):
        with self.server.guard: self.server.active += 1
        try: super().handle()
        except (EOFError, ConnectionResetError, BrokenPipeError): pass
        except Exception as cause: self.failure(type(cause).__name__)
        finally:
            with self.server.guard: self.server.active -= 1
    def await_cancel(self, websocket):
        self.connection.settimeout(self.server.cancel_timeout)
        try:
            closed = read_frame(self.connection, masked=True)[0] == 8 if websocket else self.connection.recv(1) == b''
        except (EOFError, ConnectionResetError, BrokenPipeError): closed = True
        except (socket.timeout, TimeoutError):
            self.failure('cancel_timeout'); return
        except OSError:
            self.failure('cancel_io_error'); return
        if closed: self.server.cancelled.set()
        else: self.failure('cancel_without_close')
    def events(self, request, session):
        label = marker(request)
        with self.server.guard:
            if label in self.server.seen:
                self.server.replays += 1
                raise AssertionError('Provider replayed an invocation')
            self.server.seen.add(label)
            self.server.calls += 1
            number = self.server.calls
            if label.startswith('native-') and label[7:].isdigit(): self.server.native_sessions.add(session)
        assert request['model'] == MODEL
        warm = request.get('generate') is False
        image = not warm and any(item['type'] == 'image_generation' for item in request.get('tools', []))
        encoded = self.server.large if 'large-output' in label else self.server.small
        item = {'id': f'ig_{number}', 'type': 'image_generation_call', 'status': 'completed', 'result': encoded,
                'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5}}
        response = {'id': f'resp_{number}', 'status': 'completed', 'output': [item] if image else [],
                    'usage': None if warm else {'input_tokens': 5, 'output_tokens': 7, 'input_tokens_details': {'cached_tokens': 0}}}
        events = [{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': [], 'usage': None}}]
        if 'cancel' in label: return label, events
        if image:
            events += [{'type': 'response.output_item.added', 'item': {**item, 'status': 'in_progress', 'result': None}},
                       {'type': 'response.image_generation_call.partial_image', 'item_id': item['id'], 'partial_image_index': 0, 'partial_image_b64': encoded},
                       {'type': 'response.output_item.done', 'item': item}]
        return label, events + [{'type': 'response.completed', 'response': response}]
    def do_POST(self):
        assert self.path == '/v1/responses'
        size = int(self.headers['Content-Length']); assert 0 < size <= 9 * MIB
        request = json.loads(self.rfile.read(size))
        label, events = self.events(request, None)
        streaming = request.get('stream', False)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
        self.send_header('Connection', 'close'); self.end_headers()
        if streaming:
            for event in events:
                self.wfile.write(b'data: ' + json.dumps(event, separators=(',', ':')).encode() + b'\n\n')
                self.wfile.flush()
        else:
            self.wfile.write(json.dumps(events[-1]['response']).encode()); self.wfile.flush()
        if 'cancel' in label:
            self.await_cancel(False)
        self.close_connection = True
    def do_GET(self):
        assert self.path == '/v1/responses'
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101); self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade'); self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
        with self.server.guard:
            self.server.connections += 1; session = self.server.connections
        previous = set()
        try:
            while True:
                opcode, data = read_frame(self.connection, masked=True)
                if opcode == 8: return
                assert opcode == 1
                request = json.loads(data)
                if request.get('previous_response_id'): assert request['previous_response_id'] in previous, 'Upstream connection changed'
                label, events = self.events(request, session)
                for event in events: frame(self.connection, event)
                if 'cancel' in label:
                    self.await_cancel(True); return
                previous.add(events[-1]['response']['id'])
        finally: self.close_connection = True


def request(port, token, path, value=None, *, raw=None, content_type='application/json', connection=None):
    client = connection or http.client.HTTPConnection('127.0.0.1', port, timeout=130)
    data = raw if raw is not None else json.dumps(value, separators=(',', ':')).encode() if value is not None else None
    try:
        client.request('POST' if data is not None else 'GET', path, data, {'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
        response = client.getresponse(); body = response.read()
        assert len(body) <= 32 * MIB
        return response.status, body
    finally:
        if connection is None: client.close()


def multipart(images, mask=None):
    fields = [('prompt', None, b'multipart-' + str(time.monotonic_ns()).encode())]
    fields += [('image[]', 'synthetic.png', value) for value in images]
    if mask: fields.append(('mask', 'synthetic.png', mask))
    body = bytearray()
    for name, filename, data in fields:
        body.extend(b'--boundary\r\nContent-Disposition: form-data; name="' + name.encode() + b'"')
        if filename: body.extend(b'; filename="' + filename.encode() + b'"\r\nContent-Type: image/png')
        body.extend(b'\r\n\r\n' + data + b'\r\n')
    return bytes(body + b'--boundary--\r\n')


def ws_turn(sock, value):
    frame(sock, {'type': 'response.create', **value}, masked=True)
    count = 0; result = None
    while True:
        opcode, data = read_frame(sock); assert opcode == 1
        event = json.loads(data); count += 1; assert count <= 16
        if event['type'] == 'error': raise AssertionError('Native turn rejected')
        if event['type'] == 'response.completed': result = event['response']; break
    return result


def resources(pid):
    if Path('/proc').is_dir():
        fields = dict(line.split(':', 1) for line in Path(f'/proc/{pid}/status').read_text().splitlines() if ':' in line)
        return {'rssBytes': int(fields['VmRSS'].split()[0]) * 1024, 'fds': len(list(Path(f'/proc/{pid}/fd').iterdir())), 'threads': int(fields['Threads'])}
    return {'rssBytes': int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(pid)]).strip()) * 1024}


@contextmanager
def synthetic_provider(large_size=4 * MIB, cancel_timeout=8):
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider); provider.daemon_threads = True
    worker = None
    try:
        provider.guard = threading.Lock(); provider.calls = provider.connections = 0
        provider.failures = provider.replays = provider.active = 0; provider.failure_kinds = []
        provider.seen = set(); provider.native_sessions = set(); provider.cancelled = threading.Event()
        provider.cancel_timeout = cancel_timeout
        provider.small = base64.b64encode(png(65536)).decode(); provider.large = base64.b64encode(png(large_size)).decode()
        worker = threading.Thread(target=provider.serve_forever, daemon=True); worker.start()
        yield provider
    finally:
        if worker is not None and worker.is_alive(): provider.shutdown()
        provider.server_close()
        if worker is not None and worker.ident is not None: worker.join(timeout=3)


def assert_provider_healthy(provider):
    with provider.guard:
        assert provider.replays == 0, 'Provider observed replay'
        assert provider.failures == 0, ('Provider handler failed', provider.failure_kinds)


def verify(binary, duration, transport):
    with synthetic_provider() as provider:
        with tempfile.TemporaryDirectory(prefix='codexone-desktop-boundary-') as temporary:
            root = Path(temporary); root.chmod(0o700)
            admin = root / 'admin'; admin.write_text(ADMIN); admin.chmod(0o600)
            config = root / 'config.json'
            config.write_text(json.dumps({'managedKeys': True, 'namespace': 'synthetic-boundary', 'identity': 'synthetic-boundary', 'reservedMicros': 1, 'executionTimeoutSeconds': 120,
                'upstreamBaseURL': f'http://127.0.0.1:{provider.server_port}/v1', 'upstreamTransport': transport,
                'models': [{'id': MODEL, 'visionInput': True, 'imageGeneration': True, 'inputMicrosPerMillion': 0, 'outputMicrosPerMillion': 0}],
                'imageGeneration': {'defaultModel': 'synthetic-image', 'models': [{'id': 'synthetic-image', 'hostModel': MODEL, 'sizePolicy': 'fixed1536', 'supportsTransparency': True, 'supportsInputFidelity': True, 'inputMicrosPerMillion': 0, 'outputMicrosPerMillion': 0}]}})); config.chmod(0o600)
            process, ports = start(binary, config, root, admin_token_file=admin)
            db = root / 'state/core.sqlite'; samples = []
            try:
                def key(principal):
                    status, result = call(ports['admin'], 'POST', '/api/keys', {'principal': principal, 'models': [MODEL], 'visionInput': True, 'imageGeneration': True, 'imageModels': ['synthetic-image'], 'limits': {**LIMITS, 'requests': 1000}})
                    assert status == 201; return result['secret']
                secret = key('normal'); cancelled = key('cancelled')
                def sample():
                    status, body = request(ports['admin'], ADMIN, '/api/runtime/storage'); assert status == 200
                    value = json.loads(body)
                    samples.append({'storage': value, **resources(process.pid)})
                    assert samples[-1]['rssBytes'] < 768 * MIB, 'Gateway RSS exceeds preflight envelope'
                    return value
                deadline = time.monotonic() + 12
                while sample()['pressure'] != 'normal':
                    assert time.monotonic() < deadline; time.sleep(.2)
                baseline = samples[-1]
                connection = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=130)
                native = dial(ports['data'], token=secret) if transport == 'websocket' else None
                previous = None; turns = 0; started = time.monotonic(); address = None
                try:
                    while True:
                        status, body = request(ports['data'], secret, '/v1/responses', {'model': MODEL, 'input': f'keepalive-{turns}', 'stream': False}, connection=connection)
                        assert status == 200 and json.loads(body)['status'] == 'completed'
                        assert connection.sock is not None
                        current = connection.sock.getsockname()
                        address = address or current; assert current == address, 'HTTP keepalive silently reconnected'
                        if native:
                            response = ws_turn(native, {'model': MODEL, 'input': f'native-{turns}', **({'previous_response_id': previous} if previous else {}), **({'generate': False} if turns == 0 else {})})
                            previous = response['id']; assert len(provider.native_sessions) == 1
                        turns += 1; sample()
                        if time.monotonic() - started >= duration: break
                        time.sleep(min(4, max(0, duration - (time.monotonic() - started))))
                finally:
                    connection.close()
                    if native: native.close()
                lifetime = time.monotonic() - started
                print(f"PASS: {transport} persistent sockets lifetime={lifetime:.3f}s turns={turns}", flush=True)
                for index in range(2):
                    status, body = request(ports['data'], secret, '/v1/images/edits', raw=multipart([png(3 * MIB // 2, b'\xff' if index == 1 else b'x')] * 4), content_type='multipart/form-data; boundary=boundary')
                    assert status == 200, ('multipart-max-status', status, json.loads(body).get('error', {}).get('code')); assert json.loads(body)['data'][0]['b64_json']; sample()
                status, body = request(ports['data'], secret, '/v1/images/edits', raw=multipart([png(3 * MIB)], png(3 * MIB)), content_type='multipart/form-data; boundary=boundary')
                assert status == 200; sample()
                before = provider.calls
                for images in ([png(3 * MIB // 2)] * 3 + [png(3 * MIB // 2 + 1)], [png(65536)] * 5, [png(4 * MIB + 1)]):
                    status, _ = request(ports['data'], secret, '/v1/images/edits', raw=multipart(images), content_type='multipart/form-data; boundary=boundary')
                    assert status in (400, 413)
                assert provider.calls == before, 'Rejected image reached provider'
                with socket.create_connection(('127.0.0.1', ports['data']), timeout=5) as peer:
                    peer.sendall(('POST /v1/images/edits HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' + secret + '\r\nContent-Length: 8388609\r\n\r\n').encode())
                    assert b'413' in peer.recv(4096)
                assert provider.calls == before, 'Internal envelope budget enlarged public upload limit' 
                print("PASS: " + transport + " exact 6MiB multipart, mask, overflow and external 8MiB limit", flush=True)
                data_url = 'data:image/png;base64,' + provider.large
                document = {'model': MODEL, 'input': [{'role': 'user', 'content': [{'type': 'input_text', 'text': 'tool-large-output'}, {'type': 'input_image', 'image_url': data_url}]}], 'tools': [{'type': 'image_generation'}], 'stream': True}
                status, body = request(ports['data'], secret, '/v1/responses', document)
                assert status == 200 and b'"type":"response.completed"' in body.replace(b' ', b''), ("large-tool", status, len(body), re.findall(rb'"code"\s*:\s*"([a-z_]{1,80})"', body))
                terminal = next(json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: ') and b'"response.completed"' in line)
                assert terminal['response']['output'][0]['result'] == provider.large; sample()
                if transport == 'websocket':
                    with dial(ports['data'], token=secret) as peer:
                        peer.settimeout(130)
                        result = ws_turn(peer, {**document, 'input': [{'role': 'user', 'content': [{'type': 'input_text', 'text': 'native-tool-large-output'}, {'type': 'input_image', 'image_url': data_url}]}]})
                        assert result['output'][0]['result'] == provider.large
                    sample()
                before = provider.calls
                oversized = {**document, 'input': [{'role': 'user', 'content': [{'type': 'input_text', 'text': 'oversized-image'}, {'type': 'input_image', 'image_url': 'data:image/png;base64,' + base64.b64encode(png(4 * MIB + 1)).decode()}]}]}
                assert request(ports['data'], secret, '/v1/responses', oversized)[0] == 413
                assert provider.calls == before
                provider.cancelled.clear()
                client = http.client.HTTPConnection('127.0.0.1', ports['data'], timeout=10)
                response = None
                try:
                    client.request('POST', '/v1/responses', json.dumps({'model': MODEL, 'input': 'http-cancel', 'stream': True}), {'Authorization': 'Bearer ' + cancelled, 'Content-Type': 'application/json'})
                    response = client.getresponse(); assert response.status == 200
                    for _ in range(6):
                        line = response.readline(65536)
                        if line.startswith(b'data: '):
                            assert json.loads(line[6:])['type'] == 'response.created'; break
                    else: raise AssertionError('Missing created event before cancellation')
                finally:
                    if response is not None: response.close()
                    client.close()
                assert provider.cancelled.wait(8), 'HTTP cancellation did not close upstream'
                latest(db, 'unknown'); expected_cancelled = 1
                expected_warmup = 1 if transport == 'websocket' else 0
                if transport == 'websocket':
                    provider.cancelled.clear()
                    with dial(ports['data'], token=cancelled) as peer:
                        frame(peer, {'type': 'response.create', 'model': MODEL, 'input': 'native-cancel'}, masked=True)
                        assert json.loads(read_frame(peer)[1])['type'] == 'response.created'
                    assert provider.cancelled.wait(8), 'WS cancellation did not close upstream'
                    expected_cancelled += 1
                deadline = time.monotonic() + 15
                while True:
                    with sqlite3.connect(db) as connection:
                        rows = dict(connection.execute('SELECT state,COUNT(*) FROM attempts GROUP BY state'))
                    if rows.get('intent', 0) == 0 and rows.get('unknown', 0) == expected_cancelled + expected_warmup: break
                    assert time.monotonic() < deadline, ("ledger-not-converged", transport, rows, expected_cancelled, expected_warmup); time.sleep(.1)
                assert sum(rows.values()) == provider.calls, 'Provider calls differ from durable attempts'
                for _ in range(3):
                    time.sleep(2); value = sample()
                assert time.time() - value['sampledUnixSeconds'] <= 5
                assert value['coreAvailable'] and value['pressure'] == 'normal' and value['regularQueued'] == value['criticalQueued'] == 0
                assert value['peakResidentBytes'] < 768 * MIB
                assert samples[-1]['rssBytes'] <= baseline['rssBytes'] + 256 * MIB, 'RSS did not return within bounded allocator envelope'
                if 'fds' in baseline: assert samples[-1]['fds'] <= baseline['fds'] + 6
                assert value['observedFDs'] <= baseline['storage']['observedFDs'] + 6
                with sqlite3.connect(db) as connection:
                    assert connection.execute("SELECT COUNT(*) FROM attempts WHERE state='unknown' AND principal!='cancelled' AND json_extract(admission_json,'$.mode')!='warmup'").fetchone()[0] == 0
                    assert connection.execute("SELECT COUNT(*),COALESCE(SUM(reserved),0) FROM attempts WHERE principal='normal' AND state='unknown' AND json_extract(admission_json,'$.mode')='warmup'").fetchone() == (expected_warmup, expected_warmup)
                    assert connection.execute("SELECT COUNT(*),SUM(reserved) FROM attempts WHERE principal='cancelled' AND state='unknown'").fetchone() == (expected_cancelled, expected_cancelled)
                deadline = time.monotonic() + 10
                while True:
                    with provider.guard: active = provider.active
                    if not active: break
                    assert time.monotonic() < deadline, 'Provider handlers did not retire'; time.sleep(.02)
                assert_provider_healthy(provider)
                return {'transport': transport, 'socketLifetimeSeconds': round(lifetime, 3), 'keepaliveTurns': turns, 'nativeUpstreamSessions': len(provider.native_sessions), 'providerCalls': provider.calls, 'providerReplayDetections': provider.replays, 'providerFailures': provider.failures, 'providerActiveHandlers': active, 'expectedCancelledUnknown': expected_cancelled, 'expectedWarmupUnknown': expected_warmup, 'ledger': rows, 'samples': samples}
            finally: stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=125)
    parser.add_argument('--transport', choices=['http', 'websocket', 'both'], default='both')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(); assert 3 <= args.duration <= 300
    if args.output: assert not args.output.exists() and args.output.parent.is_dir()
    result = {'reportVersion': 1, 'verificationSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'python': platform.python_version(), 'platform': platform.system(), 'architecture': platform.machine(), 'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'longLifetimeSample': args.duration >= 125,
              'results': [verify(str(args.binary.resolve()), args.duration, transport) for transport in (('http', 'websocket') if args.transport == 'both' else (args.transport,))]}
    if args.output: args.output.write_text(json.dumps(result, indent=2)); args.output.chmod(0o600)
    print('PASS: synthetic Desktop socket/image boundaries; platform=' + result['platform'] + '; longLifetime=' + str(result['longLifetimeSample']) + '; transports=' + args.transport)


if __name__ == '__main__': main()
