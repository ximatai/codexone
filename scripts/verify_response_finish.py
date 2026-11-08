#!/usr/bin/env python3
"""Synthetic real-binary socket matrix for terminal delivery and transport closure."""
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

from verify_protocol import TOKEN, start, stop
from verify_text_contract import FIXTURE, rows
from verify_websocket import dial, receive, send


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def events(self):
        assert self.headers.get('Authorization') is None
        self.server.calls += 1
        return json.loads(FIXTURE.read_text())['events']

    def emit(self, write):
        events = self.events()
        for event in events[:-1]:
            write(event)
        self.server.started.set()
        assert self.server.release.wait(5)
        if self.server.case.startswith('upstream-before-terminal'):
            return
        write(events[-1])

    def do_POST(self):
        self.close_connection = True
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert request['stream'] is True  # subscription contract, even for downstream JSON
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        def write(event):
            self.wfile.write(b'data: ' + json.dumps(event).encode() + b'\n\n')
            self.wfile.flush()
        try:
            self.emit(write)
            if self.server.case not in ('upstream-terminal-close', 'upstream-before-terminal'):
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
        except OSError:
            pass

    def do_GET(self):
        self.close_connection = True
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        for name, value in [('Upgrade', 'websocket'), ('Connection', 'Upgrade'), ('Sec-WebSocket-Accept', accept)]:
            self.send_header(name, value)
        self.end_headers()
        try:
            opcode, body = receive(self.connection, masked=True)
            assert opcode == 1 and json.loads(body)['model'] == 'synthetic-contract'
            self.emit(lambda event: send(self.connection, event))
            if self.server.case in ('upstream-terminal-eof', 'upstream-before-terminal-eof'):
                return
            if self.server.case in ('upstream-terminal-close', 'upstream-before-terminal'):
                send(self.connection, struct.pack('!H', 1011) + b'synthetic-private-close-reason', opcode=8)
                return
            self.connection.settimeout(3)
            while True:
                opcode, body = receive(self.connection, masked=True)
                if opcode == 8:
                    send(self.connection, body, opcode=8)
                    return
        except (OSError, EOFError):
            pass


def reset(peer):
    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    peer.close()


def http_peer(port, route, keep_alive):
    peer = socket.create_connection(('127.0.0.1', port), timeout=5)
    body = json.dumps(dict(model='synthetic-contract', input='synthetic finish', stream=route == 'sse')).encode()
    connection = 'keep-alive' if keep_alive else 'close'
    peer.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\n'
                  f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: {connection}\r\n\r\n').encode() + body)
    return peer


def client(port, route, case, server, keep_alive):
    peer = dial(port) if route == 'native' else http_peer(port, route, keep_alive)
    received = bytearray()
    types = []
    status = None
    try:
        if route == 'native':
            send(peer, dict(type='response.create', model='synthetic-contract', input='synthetic finish'), masked=True)
        assert server.started.wait(5)
        if case == 'before-terminal':
            if route == 'native':
                opcode, body = receive(peer)
                assert opcode == 1 and json.loads(body)['type'] == 'response.created'
            elif route == 'sse':
                response = http.client.HTTPResponse(peer)
                response.begin()
                while not received.endswith(b'\n\n'):
                    received.extend(response.read1())
                assert b'response.created' in received
                response.close()
            reset(peer)
            time.sleep(.05)  # let the socket owner observe RST before releasing upstream
            server.release.set()
            return 'no response yet' if route == 'json' else 'response.created; disconnected before terminal'
        server.release.set()
        if route == 'native':
            while True:
                opcode, body = receive(peer)
                if opcode == 8:
                    break
                assert opcode == 1
                event = json.loads(body)
                types.append(event['type'])
                if event['type'] == 'error':
                    assert event['status'] == 502 and event['error']['code'] == 'execution_indeterminate', event
                if event['type'] == 'response.completed':
                    assert event['response']['usage']['input_tokens'] == 5
                    assert types.count('response.completed') == 1
                    if case == 'after-terminal':
                        reset(peer)
                        break
                    # Keep reading briefly to detect a spurious error after success.
                    peer.settimeout(.3)
            return ','.join(types)
        response = http.client.HTTPResponse(peer)
        response.begin()
        status = response.status
        while True:
            part = response.read1()
            if not part:
                break
            received.extend(part)
            if route == 'sse':
                terminal = received.endswith(b'\n\n') and b'"type":"response.completed"' in received.replace(b' ', b'')
            else:
                terminal = response.length == 0
            if case in ('after-terminal', 'before-done') and terminal:
                response.close()
                reset(peer)
                break
            if case == 'after-done' and received.endswith(b'data: [DONE]\n\n'):
                response.close()
                reset(peer)
                break
        if case == 'next-request-reset':
            peer.sendall((f'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{{').encode())
            time.sleep(.05)  # the next head/body must be observed, without a complete request
            reset(peer)
        if route == 'json' and received:
            result = json.loads(received)
            if result.get('status') == 'completed':
                assert result['usage']['input_tokens'] == 5 and result['usage']['output_tokens'] == 3
            types.append(result.get('status', result.get('error', {}).get('code', 'other')))
        elif route == 'sse':
            types += [json.loads(line[6:])['type'] for line in received.splitlines() if line.startswith(b'data: {')]
            if b'data: [DONE]' in received:
                types.append('[DONE]')
        return f'HTTP {status}: ' + ','.join(types)
    except (socket.timeout, TimeoutError):
        return (f'HTTP {status}: ' if status else '') + ','.join(types) + '; idle'
    except (EOFError, ConnectionError, http.client.IncompleteRead):
        return (f'HTTP {status}: ' if status else '') + ','.join(types) + ('; socket ended' if types else '; no complete terminal')
    finally:
        peer.close()
        server.release.set()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--keep-alive', action='store_true', default=None, help='Use persistent HTTP response framing')
    parser.add_argument('--route', choices=('sse', 'json', 'native'))
    parser.add_argument('--case')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--baseline', action='store_true', help='Record pre-fix evidence without post-fix log assertions')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-finish-') as temporary:
            paths = [(t, r, False) for t, r in [('http', 'sse'), ('http', 'json'), ('websocket', 'sse'), ('websocket', 'json'), ('websocket', 'native')]]
            persistent = [(t, r, True) for t in ('http', 'websocket') for r in ('sse', 'json')]
            paths = persistent if args.keep_alive else paths + persistent
            for transport, route, keep_alive in paths:
                if args.route and args.route != route:
                    continue
                cases = ['normal', 'before-terminal', 'after-terminal', 'upstream-terminal-close', 'upstream-before-terminal']
                if transport == 'websocket':
                    cases += ['upstream-terminal-eof', 'upstream-before-terminal-eof']
                if keep_alive:
                    cases += ['next-request-reset']
                if route == 'sse':
                    cases += ['before-done', 'after-done']
                for case in cases:
                    if args.case and args.case != case:
                        continue
                    for iteration in range(args.repeat):
                        server.case = case
                        server.calls = 0
                        server.started, server.release = threading.Event(), threading.Event()
                        root = Path(temporary) / f'{transport}-{route}-{keep_alive}-{case}-{iteration}'
                        root.mkdir()
                        config = root / 'identity.json'
                        config.write_text(json.dumps(dict(principal='synthetic-finish', keyID='synthetic-key',
                            keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-finish',
                            identity='synthetic-identity', models=[dict(id='synthetic-contract', inputMicrosPerMillion=0,
                            outputMicrosPerMillion=0)], reservedMicros=1, upstreamContract='codex-subscription',
                            upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1', upstreamTransport=transport,
                            executionTimeoutSeconds=5)))
                        config.chmod(0o600)
                        process, ports = start(str(args.binary.resolve()), config, root)
                        try:
                            result = client(ports['data'], route, case, server, keep_alive)
                            deadline = time.monotonic() + 6
                            while True:
                                records = rows(root)
                                if records and records[0][0] != 'intent':
                                    break
                                assert time.monotonic() < deadline, records
                                time.sleep(.02)
                            time.sleep(.1)
                            process.terminate()
                            process.wait(10)
                            logs = process.stdout.read().decode()
                            with sqlite3.connect(root / 'state/core.sqlite') as db:
                                request_id, incomplete_reason = db.execute(
                                    "SELECT request_id,json_extract(outcome_json,'$.upstreamIncompleteReason') FROM attempts"
                                ).fetchone()
                                assert incomplete_reason is None
                            protocol = [line.split('codexone.protocol:', 1)[-1].strip() for line in logs.splitlines() if 'codexone.protocol:' in line]
                            assert len(records) == 1 and server.calls == 1, 'Unexpected admission or replay'
                            protocol = [line + (' [attempt]' if f'request_id={request_id}' in line else ' [no attempt]') if 'request_id=' in line else line for line in protocol]
                            state, outcome, usage = records[0]
                            completeness = usage['completeness'] if usage else 'none'
                            print(f'{transport}/{route}/{"keep-alive" if keep_alive else "close"}/{case}: {result} | {state}/{outcome}/{completeness} | {protocol}', flush=True)
                            if case.startswith('upstream-before-terminal'):
                                assert state == 'unknown' and outcome != 'succeeded' and usage is None, records
                                assert 'error' in result or 'execution_indeterminate' in result, result
                                if route == 'json':
                                    assert 'HTTP 502:' in result, result
                                assert any('Protocol request rejected' in line and 'execution_indeterminate' in line and '[attempt]' in line for line in protocol), protocol
                                if transport == 'websocket' and not args.baseline:
                                    if case.endswith('-eof'):
                                        assert any('reason=upstream_websocket_eof' in line for line in protocol), protocol
                                    else:
                                        assert any('reason=upstream_websocket_close' in line and 'upstream_ws_close_code=1011' in line for line in protocol), protocol
                            elif case == 'before-terminal':
                                assert outcome == 'cancelled', records
                                if route == 'native':
                                    assert state == 'settled' and completeness == 'complete', records
                                else:
                                    assert state == 'unknown' and usage is None, records
                                    assert any('Protocol request rejected' in line and '[attempt]' in line for line in protocol), protocol
                            else:
                                assert state == 'settled' and outcome == 'succeeded' and completeness == 'complete', records
                                assert 'error' not in result and 'completed' in result, result
                                if not args.baseline:
                                    if case == 'next-request-reset':
                                        assert any('Protocol request rejected' in line and '[no attempt]' in line for line in protocol), protocol
                                        assert not any('Protocol request rejected' in line and '[attempt]' in line for line in protocol), protocol
                                    else:
                                        assert not any('Protocol request rejected' in line for line in protocol), protocol
                            for line in protocol:
                                if 'Response stream finish failed after execution' in line or 'Response cleanup after completion' in line:
                                    assert any(' info codexone.protocol:' in raw and ('Response stream finish failed after execution' in raw or 'Response cleanup after completion' in raw) for raw in logs.splitlines()), line
                                    assert 'status=' not in line and 'code=' not in line, line
                                    assert any(f'reason={reason}' in line for reason in ('downstream_done_write', 'downstream_end_write', 'execution_cleanup_cancelled', 'downstream_idle_read')), line
                            assert 'synthetic-private-close-reason' not in logs
                            assert TOKEN not in logs and 'synthetic independent contract output' not in logs
                        finally:
                            stop(process)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(10)


if __name__ == '__main__':
    main()
