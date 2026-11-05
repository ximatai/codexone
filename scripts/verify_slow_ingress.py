#!/usr/bin/env python3
"""Real loopback HTTP: paced unbuffered-style ingress, timeout/end races and JSON errors."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
import time

from verify_protocol import TOKEN, start, stop, dump_gateway_failure
from verify_json_order import wire, EVENT


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_POST(self):
        self.close_connection = True
        document = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with self.server.guard:
            self.server.calls += 1
        if document['input'] == 'drop':
            return
        body = wire(EVENT['response'])
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def request_head(length, chunked=False):
    framing = 'Transfer-Encoding: chunked' if chunked else f'Content-Length: {length}'
    return (f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n'
            f'Content-Type: application/json\r\n{framing}\r\nConnection: close\r\n\r\n').encode()


def read_reply(peer):
    response = http.client.HTTPResponse(peer)
    response.begin()
    assert response.getheader('Content-Type').startswith('application/json')
    document = json.loads(response.read())
    return response.status, document


def paced(port, chunked):
    body = wire(dict(model='synthetic-order', input='x' * (12 * 1024 * 1024), stream=False))
    with socket.create_connection(('127.0.0.1', port), timeout=20) as peer:
        peer.sendall(request_head(len(body), chunked))
        begin = time.monotonic()
        for offset in range(0, len(body), 128 * 1024):
            part = body[offset:offset + 128 * 1024]
            peer.sendall((f'{len(part):x}\r\n'.encode() + part + b'\r\n') if chunked else part)
            time.sleep(.12)
        if chunked:
            peer.sendall(b'0\r\n\r\n')
        status, document = read_reply(peer)
        assert status == 200 and document['status'] == 'completed', (status, document)
        assert time.monotonic() - begin > 10


def end_race(port, delay):
    body = wire(dict(model='synthetic-order', input='synthetic-race', stream=False))
    with socket.create_connection(('127.0.0.1', port), timeout=15) as peer:
        peer.sendall(request_head(len(body)) + body[:-1])
        time.sleep(delay)
        try:
            peer.sendall(body[-1:])
        except OSError:
            pass  # A complete 408 can already be queued before the close reaches the sender.
        status, document = read_reply(peer)
        assert status in (200, 408), (status, document)
        if status == 408:
            assert document['error']['code'] == 'request_body_timeout'
        return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.daemon_threads = True
    server.calls, server.guard = 0, threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='codexone-slow-ingress-') as directory:
        root = Path(directory)
        config = root / 'identity.json'
        config.write_text(json.dumps(dict(principal='synthetic', keyID='synthetic-key',
            namespace='synthetic', identity='synthetic-account',
            keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), reservedMicros=1,
            models=[dict(id='synthetic-order', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
            upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1', upstreamTransport='http')))
        config.chmod(0o600)
        process = None
        try:
            process, ports = start(str(args.binary.resolve()), config, root)
            port = ports['data']
            with ThreadPoolExecutor(max_workers=4) as workers:
                jobs = [workers.submit(paced, port, chunked) for chunked in (False, True)]
                for job in jobs:
                    job.result()
                assert server.calls == 2
                races = list(workers.map(lambda delay: end_race(port, delay), (9.85, 10.0, 10.2)))
            expected = 2 + races.count(200)
            assert server.calls == expected
            with socket.create_connection(('127.0.0.1', port), timeout=15) as peer:
                peer.sendall(request_head(32 * 1024 * 1024) + b'{')
                begin = time.monotonic()
                status, document = read_reply(peer)
                assert status == 408 and document['error']['code'] == 'request_body_timeout'
                assert 9.5 <= time.monotonic() - begin < 12
            # Partial-body cancellation must return the 32 MiB lease before a large healthy request.
            with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
                peer.sendall(request_head(32 * 1024 * 1024) + b'{')
            time.sleep(.2)
            body = wire(dict(model='synthetic-order', input='x' * (20 * 1024 * 1024), stream=False))
            with socket.create_connection(('127.0.0.1', port), timeout=20) as peer:
                peer.sendall(request_head(len(body)) + body)
                assert read_reply(peer)[0] == 200
            expected += 1
            # A raw unmapped AHC failure preserves unknown and returns a complete JSON envelope.
            body = wire(dict(model='synthetic-order', input='drop', stream=False))
            with socket.create_connection(('127.0.0.1', port), timeout=10) as peer:
                peer.sendall(request_head(len(body)) + body)
                status, document = read_reply(peer)
                assert status == 502 and document['error']['code'] == 'execution_indeterminate'
            expected += 1
            deadline = time.monotonic() + 5
            while True:
                with sqlite3.connect(root / 'state/core.sqlite') as db:
                    rows = db.execute('SELECT state,usage_json,outcome_json FROM attempts ORDER BY rowid').fetchall()
                if len(rows) == expected and all(row[0] != 'intent' for row in rows):
                    break
                assert time.monotonic() < deadline, rows
                time.sleep(.02)
            assert server.calls == expected == len(rows), (server.calls, expected, rows)
            assert all(row[0] == 'settled' for row in rows[:-1])
            assert rows[-1][0] == 'unknown' and rows[-1][1] is None
            process.terminate(); process.wait(10)
            logs = process.stdout.read()
            assert b'cause=remoteConnectionClosed' in logs, logs[-4000:]
            assert TOKEN.encode() not in logs and b'synthetic-race' not in logs
            print('PASS: concurrent paced Content-Length/chunked >10s, timeout/end races, 408 JSON, cancellation/budget release, unmapped cause, single dispatch and ledger')
        except BaseException:
            if process:
                dump_gateway_failure(process)
            raise
        finally:
            if process:
                stop(process)
            server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
