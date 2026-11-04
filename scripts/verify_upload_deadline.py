#!/usr/bin/env python3
"""Real gateway process, synthetic loopback upload/backpressure and settlement matrix."""
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
from verify_json_order import wire, EVENT
from verify_websocket import send, apply_mask
from verify_keys import ADMIN, LIMITS, call
from verify_images import native_body

FIRST = 2
TOTAL = 12


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def read_body(self, length, mask=None):
        self.server.calls += 1
        self.server.started_at = time.monotonic()
        self.server.started.set()
        if self.server.case in ('stalled', 'cancel'):
            # Leave far more than a socket buffer unread until the gateway exits.
            self.server.release.wait(15)
            return None
        body = bytearray()
        while len(body) < length:
            part = self.rfile.read(min(64 * 1024, length - len(body)))
            if not part:
                return None
            body.extend(part)
            # Pace the prefix beyond FIRST, then drain the buffered tail promptly.
            # This measures transport completion without treating remote consumption
            # of several MiB of macOS socket buffers as an upload acknowledgement.
            if self.server.case in ('slow', 'slow-silent', 'trickle') and len(body) < length - 6 * 1024 * 1024:
                time.sleep(.05 if self.server.case == 'trickle' else .01 if self.server.transport in ('http', 'images') else .035)
        self.server.read_at = time.monotonic()
        self.server.body = apply_mask(body, mask) if mask else bytes(body)
        self.server.read_done.set()
        if self.server.case in ('silent', 'slow-silent'):
            self.server.release.wait(15)
            return None
        return self.server.body

    def do_POST(self):
        self.close_connection = True
        try:
            assert self.headers.get('Transfer-Encoding') is None
            assert self.headers['Content-Type'] == 'application/json'
            assert self.headers['Accept'] == 'application/json'
            if self.read_body(int(self.headers['Content-Length'])) is None:
                return
            body = native_body('synthetic') if self.server.transport == 'images' else wire(EVENT['response'])
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (OSError, EOFError):
            pass

    def do_GET(self):
        self.close_connection = True
        try:
            accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            for key, value in [('Upgrade', 'websocket'), ('Connection', 'Upgrade'), ('Sec-WebSocket-Accept', accept)]:
                self.send_header(key, value)
            self.end_headers()
            head = self.rfile.read(2)
            assert head[0] == 0x81 and head[1] & 128
            length = head[1] & 127
            if length == 126:
                length = struct.unpack('!H', self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.rfile.read(8))[0]
            mask = self.rfile.read(4)
            if self.read_body(length, mask) is None:
                return
            send(self.connection, wire(EVENT))
            self.server.release.wait(15)
        except (OSError, EOFError):
            pass


def ledger(root):
    with sqlite3.connect(root / 'state/core.sqlite') as db:
        records = db.execute('SELECT state,outcome_json,usage_json FROM attempts').fetchall()
        assert db.execute('SELECT COUNT(*) FROM account_health').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM account_model_health').fetchone()[0] == 0
    return [(state, json.loads(outcome) if outcome else None, json.loads(usage) if usage else None)
            for state, outcome, usage in records]


def run(binary, root, transport, case):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.case, server.calls, server.body = case, 0, None
    server.transport = transport
    server.started, server.release, server.read_done = threading.Event(), threading.Event(), threading.Event()
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    config = root / 'identity.json'
    config.write_text(json.dumps(dict(principal='synthetic-upload', keyID='synthetic-key',
        namespace='synthetic-upload', identity='synthetic-account',
        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
        models=[dict(id='synthetic-order', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
        reservedMicros=1, upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',
        upstreamTransport='http' if transport == 'images' else transport, executionTimeoutSeconds=TOTAL, firstResponseTimeoutSeconds=FIRST,
        **(dict(managedKeys=True, imageGeneration=dict(defaultModel='synthetic-image', models=[dict(id='synthetic-image', inputMicrosPerMillion=0, outputMicrosPerMillion=0)])) if transport == 'images' else {}))))
    if transport == 'images':
        document = json.loads(config.read_text())
        for key in ('principal', 'keyID', 'keySHA256'):
            document.pop(key)
        document['progressTimeoutSeconds'] = 4
        config.write_text(json.dumps(document))
    config.chmod(0o600)
    process = None
    peer = None
    try:
        admin = root / 'admin'
        admin.write_text(ADMIN); admin.chmod(0o600)
        process, ports = start(binary, config, root, admin_token_file=admin if transport == 'images' else None)
        client_token = TOKEN
        if transport == 'images':
            status, created = call(ports['admin'], 'POST', '/api/keys', dict(principal='synthetic', models=[], limits=LIMITS, imageGeneration=True, imageModels=['synthetic-image']))
            assert status == 201, created
            client_token = created['secret']
        # 28 MiB HTTP and 12 MiB WS force backpressure without crossing either body limit.
        request = dict(model='synthetic-order', input='synthetic-upload-' + 'x' * ((28 if transport == 'http' else 12) * 1024 * 1024), stream=False)
        if transport == 'images':
            request = dict(model='synthetic-image', future='x' * (28 * 1024 * 1024), stream=False)
        body = wire(request)
        peer = socket.create_connection(('127.0.0.1', ports['data']), timeout=20)
        begin = time.monotonic()
        path = '/v1/images/edits' if transport == 'images' else '/v1/responses'
        peer.sendall((f'POST {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {client_token}\r\n'
                      f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n').encode() + body)
        assert server.started.wait(5), 'Provider did not receive request'
        if case == 'cancel':
            time.sleep(.3)
            cancel_at = time.monotonic()
            peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            peer.close()
        else:
            response = http.client.HTTPResponse(peer)
            response.begin()
            result = response.read()
            end = time.monotonic()
            if case == 'slow':
                assert response.status == 200 and (json.loads(result).get('data') if transport == 'images' else json.loads(result)['status'] == 'completed'), (response.status, result[:200])
                assert server.read_at - server.started_at > FIRST, 'Upload did not cross first deadline'
            else:
                code = ('execution_first_response_timeout' if case in ('silent', 'slow-silent') else
                        'execution_progress_timeout' if case == 'stalled' and transport == 'images' else 'execution_deadline_exceeded')
                assert response.status == 504 and json.loads(result)['error']['code'] == code, (response.status, result[:200])
                if case in ('silent', 'slow-silent'):
                    assert server.read_done.is_set()
                    # Transport completion can precede remote read by the bounded tail in socket buffers.
                    assert FIRST - .7 <= end - server.read_at <= FIRST + 1, end - server.read_at
                    if case == 'slow-silent':
                        assert server.read_at - server.started_at > FIRST
                        assert end - server.started_at > FIRST + 2
                else:
                    limit = 4 if case == 'stalled' and transport == 'images' else TOTAL
                    assert limit - .5 <= end - begin <= limit + 2, end - begin
        deadline = time.monotonic() + (3 if case == 'cancel' else 5)
        while True:
            records = ledger(root)
            if records and records[0][0] != 'intent':
                break
            assert time.monotonic() < deadline, records
            time.sleep(.02)
        assert len(records) == 1 and server.calls == 1, (records, server.calls)
        state, outcome, usage = records[0]
        if case == 'slow':
            assert state == 'settled' and outcome['kind'] == 'succeeded' and usage['completeness'] == 'complete', records
        else:
            expected = 'client_cancelled' if case == 'cancel' else 'deadline_exceeded'
            assert state == 'unknown' and outcome['failure'] == expected and usage is None, records
        if case == 'cancel':
            assert time.monotonic() - cancel_at < 3, 'Cancellation did not settle promptly'
        if server.body is not None:
            expected = request if transport in ('http', 'images') else {k: v for k, v in request.items() if k != 'stream'}
            if transport == 'websocket':
                expected['type'] = 'response.create'
            assert server.body == wire(expected), 'Encoded body bytes changed'
        server.release.set()
        process.terminate()
        process.wait(10)
        logs = process.stdout.read()
        uploads = [line for line in logs.splitlines() if b'Upstream request upload' in line]
        assert len(uploads) == 1, uploads
        size_bucket = b'size_bucket=24_to_32_mib' if transport in ('http', 'images') else b'size_bucket=at_most_16_mib'
        assert size_bucket in uploads[0] and b'upload_duration_bucket=' in uploads[0], uploads
        expected_result = b'result=interrupted' if case in ('stalled', 'cancel', 'trickle') else b'result=sent'
        assert expected_result in uploads[0], uploads
        assert TOKEN.encode() not in logs and b'synthetic-upload-' not in logs
        print(f'PASS: {transport}/{case}: timing, single dispatch, body bytes, ledger, health, bounded diagnostic', flush=True)
    except BaseException:
        if process:
            dump_gateway_failure(process)
        raise
    finally:
        if peer:
            peer.close()
        server.release.set()
        if process:
            stop(process)
        server.shutdown()
        server.server_close()
        worker.join(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--transport', choices=['http', 'websocket', 'images'])
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='codexone-upload-') as temporary:
        for transport in ([args.transport] if args.transport else ('http', 'websocket', 'images')):
            cases = ('slow', 'silent', 'slow-silent', 'stalled', 'cancel')
            for case in cases + (('trickle',) if transport == 'images' else ()):
                root = Path(temporary) / f'{transport}-{case}'
                root.mkdir()
                run(str(args.binary.resolve()), root, transport, case)


if __name__ == '__main__':
    main()
