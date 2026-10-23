#!/usr/bin/env python3
"""Independent literal protocol shapes over HTTP/JSON/SSE and bridge/native WS; no live accounts."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sqlite3
import tempfile
import threading
import time

from verify_protocol import TOKEN, connect, start, stop
from verify_websocket import dial, receive, send

FIXTURE = Path(__file__).resolve().parents[1] / 'Tests/CodexOneAdaptersTests/Fixtures/provider-text-contract.json'
PRIVATE = 'synthetic independent contract output'
CASES = ['ok', 'details-empty', 'sparse-stream', 'large-echo', 'event-oversized', 'incomplete', 'timestamp-string', 'timestamp-null',
         'instructions-boolean', 'instructions-object', 'instructions-scalars', 'instructions-capacity',
         'details-boolean', 'details-reason', 'status-conflict', 'status-unknown',
         'total-negative', 'total-null', 'total-fraction', 'total-conflict', 'foreign-terminal', 'foreign-delta']


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def sequence(self, request):
        assert request['model'] == 'synthetic-contract'
        assert self.headers.get('Authorization') is None
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        events = json.loads(self.server.literal.replace('resp_contract_1', f'resp_contract_{index}')
                            .replace('msg_contract_1', f'msg_contract_{index}'))
        result = events[-1]['response']
        if isinstance(request.get('input'), list) and len(request['input']) > 1:
            assert any(item.get('role') == 'assistant' and item['content'][0]['text'] == PRIVATE
                       for item in request['input'])
        mode = self.server.mode
        if mode == 'event-oversized':
            return [dict(type='synthetic.extension', data='x' * 1048577)]
        if mode == 'sparse-stream':
            events[2]['response_id'] = result['id']
            result.pop('status')
            return [events[2], events[-1]]
        elif mode == 'large-echo':
            assert request['instructions'] == 'synthetic-large-echo-' + 'x' * 300000
            result['instructions'] = 'synthetic-large-echo-' + 'x' * 300000
        elif mode == 'details-empty':
            result['incomplete_details'] = {}
        elif mode == 'incomplete':
            events[-1]['type'] = 'response.incomplete'
            result['status'] = 'incomplete'
            result['incomplete_details'] = {}
        elif mode.startswith('timestamp-'):
            result['created_at'] = 'synthetic-invalid-date' if mode.endswith('string') else None
        elif mode.startswith('instructions-'):
            result['instructions'] = {'boolean': False, 'object': {}, 'scalars': [False],
                                      'capacity': [{}] * 129}[mode.removeprefix('instructions-')]
        elif mode == 'details-boolean':
            result['incomplete_details'] = False
        elif mode == 'details-reason':
            result['incomplete_details'] = {'reason': 1}
        elif mode.startswith('status-'):
            result['status'] = 'failed' if mode.endswith('conflict') else 'synthetic-unknown-status'
        elif mode.startswith('total-'):
            result['usage']['total_tokens'] = {'negative': -1, 'null': None, 'fraction': 8.5,
                                               'conflict': 9}[mode.removeprefix('total-')]
        elif mode == 'foreign-terminal':
            result['id'] = 'synthetic-foreign-response'
            result['usage'] = {'input_tokens': 9999, 'output_tokens': 9999, 'total_tokens': 19998,
                               'input_tokens_details': {'cached_tokens': 0}}
        elif mode == 'foreign-delta':
            events[2]['response_id'] = 'synthetic-foreign-response'
        if mode in ('ok', 'details-empty'):
            events.insert(0, {'type': 'synthetic.extension', 'response': {'id': 'synthetic-foreign-response'},
                              'usage': {'input_tokens': 9999}})
        return events

    def do_POST(self):
        self.close_connection = True
        assert self.path == '/v1/responses'
        length = int(self.headers['Content-Length'])
        assert 0 < length <= 524288
        request = json.loads(self.rfile.read(length))
        events = self.sequence(request)
        if request.get('stream'):
            data = ''.join('data: ' + json.dumps(event) + '\n\n' for event in events).encode()
            # Omit the streaming media type, as independently observed on the subscription path.
            mime = None
        else:
            data = json.dumps(events[-1]['response']).encode()
            mime = 'application/json'
        self.send_response(200)
        if mime:
            self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.close_connection = True
        assert self.path == '/v1/responses' and self.headers.get('Authorization') is None
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.connection.settimeout(8)
        try:
            while True:
                opcode, body = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                if opcode == 9:
                    send(self.connection, body, opcode=10)
                    continue
                assert opcode == 1
                for event in self.sequence(json.loads(body)):
                    send(self.connection, event, maximum_bytes=2 * 1048576)
        except (OSError, EOFError):
            return


def native(port, request):
    with dial(port) as client:
        send(client, {'type': 'response.create', **request}, masked=True)
        events = []
        while True:
            opcode, body = receive(client)
            assert opcode == 1
            event = json.loads(body)
            events.append(event)
            if event.get('type') in ('response.completed', 'response.incomplete', 'response.failed', 'error'):
                return 200, events
            assert len(events) < 20


def call(port, route, request):
    if route == 'native':
        return native(port, request)
    status, body = connect(port, 'POST', '/v1/responses', {**request, 'stream': route == 'sse'})
    if route == 'json' or status != 200:
        return status, [json.loads(body)]
    return status, [json.loads(line[6:]) for line in body.splitlines()
                    if line.startswith(b'data: ') and line[6:] != b'[DONE]']


def rows(root):
    with sqlite3.connect(root / 'state/core.sqlite') as db:
        return [(s, json.loads(o)['kind'] if o else None, json.loads(u) if u else None)
                for s, o, u in db.execute('SELECT state,outcome_json,usage_json FROM attempts ORDER BY rowid')]


def outcomes(root):
    with sqlite3.connect(root / 'state/core.sqlite') as db:
        return [json.loads(row[0]) if row[0] else None
                for row in db.execute('SELECT outcome_json FROM attempts ORDER BY rowid')]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--case', choices=CASES)
    parser.add_argument('--transport', choices=('http', 'websocket'))
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.guard = threading.Lock()
    provider.calls = 0
    provider.literal = json.dumps(json.loads(FIXTURE.read_text())['events'])
    thread = threading.Thread(target=provider.serve_forever)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-text-contract-') as temporary:
            for transport in ((args.transport,) if args.transport else ('http', 'websocket')):
                transport_start = provider.calls
                for mode in ([args.case] if args.case else CASES):
                    if transport == 'websocket' and mode == 'sparse-stream':
                        continue  # Preserve native WS's existing stronger created/turn barrier.
                    provider.mode = mode
                    root = Path(temporary) / (transport + '-' + mode)
                    root.mkdir(mode=0o700)
                    config = root / 'identity.json'
                    config.write_text(json.dumps(dict(principal='synthetic-contract', keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-contract',
                        identity='synthetic-identity', models=[dict(id='synthetic-contract', inputMicrosPerMillion=0,
                        outputMicrosPerMillion=0)], reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1', upstreamTransport=transport)))
                    config.chmod(0o600)
                    process, ports = start(binary, config, root)
                    before = provider.calls
                    count = 0
                    try:
                        for route in (('sse', 'json') if transport == 'http' else ('sse', 'json', 'native')):
                            # JSON alone cannot prove a conflict with an earlier event.
                            if transport == 'http' and route == 'json' and mode.startswith('foreign-'):
                                continue
                            if transport == 'http' and route == 'json' and mode.startswith('status-'):
                                continue  # A JSON response has no conflicting SSE event name.
                            if route == 'json' and mode == 'event-oversized':
                                continue
                            if route == 'json' and mode == 'sparse-stream':
                                continue
                            request = dict(model='synthetic-contract', input=[dict(role='user', content='synthetic contract')])
                            if mode == 'large-echo':
                                request['instructions'] = 'synthetic-large-echo-' + 'x' * 300000
                            status, events = call(ports['data'], route, request)
                            count += 1
                            assert events, (transport, mode, route, status)
                            result = events[-1]
                            if mode in ('ok', 'details-empty', 'sparse-stream', 'large-echo', 'incomplete'):
                                assert status == 200 and 'error' not in result, (transport, mode, route, events)
                                response = result.get('response', result)
                                assert response['created_at'] == 1.125
                                if mode == 'large-echo':
                                    assert response['instructions'] == 'synthetic-large-echo-' + 'x' * 300000
                                else:
                                    assert response['instructions'] == json.loads(provider.literal)[-1]['response']['instructions']
                                if mode != 'incomplete':
                                    request['input'] += response['output'] + [dict(role='user', content='synthetic next turn')]
                                    status, events = call(ports['data'], route, request)
                                    count += 1
                                    assert status == 200 and 'error' not in events[-1]
                            else:
                                assert 'error' in result and result['error']['request_id'] in result['error']['message'], (transport, mode, route, events)
                        deadline = time.monotonic() + 3
                        while len(rows(root)) != count or any(s == 'intent' for s, _, _ in rows(root)):
                            assert time.monotonic() < deadline
                            time.sleep(.02)
                        process.terminate()
                        process.wait(10)
                        logs = process.stdout.read()
                        assert provider.calls == before + count, 'Unexpected replay or dispatch'
                        records = rows(root)
                        if mode.startswith('foreign-') or mode == 'event-oversized':
                            assert all(s == 'unknown' and u is None for s, _, u in records), records
                        else:
                            assert all(s == 'settled' and u and u['completeness'] == 'complete'
                                       and u['inputTokens'] == 5 and u['outputTokens'] == 3 for s, _, u in records), records
                            assert all(k == ('succeeded' if mode in ('ok', 'details-empty', 'sparse-stream', 'large-echo') else 'failed')
                                       for _, k, _ in records), (transport, mode, records, outcomes(root))
                        with sqlite3.connect(root / 'state/core.sqlite') as db:
                            assert db.execute('SELECT count(*) FROM bindings WHERE raw_id IN (?,?)',
                                              ('synthetic-metadata-only-id', 'synthetic-foreign-response')).fetchone()[0] == 0
                        assert PRIVATE.encode() not in logs and b'synthetic echoed guidance' not in logs
                        assert TOKEN.encode() not in logs and b'synthetic-metadata-only-id' not in logs
                    finally:
                        stop(process)
                print(f'PASS: {transport} {provider.calls - transport_start} independent literal JSON/SSE/native executions, full-window continuation, '
                      'strict typed metadata/status/totals, response identity, durable usage/unknown and no replay or private logs', flush=True)
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(10)


if __name__ == '__main__':
    main()
