#!/usr/bin/env python3
"""Raw JSON byte contracts through the gateway binary; loopback synthetic providers only."""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading

from verify_protocol import TOKEN, start, stop
from verify_websocket import dial, receive, send


def wire(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


# Deliberately nonalphabetical at every level, including tools[].parameters.properties.
SCHEMA = {'type': 'function', 'name': 'synthetic_tool', 'parameters': {
    'required': ['zeta'], 'properties': {
        'zeta': {'description': 'synthetic', 'type': 'string'},
        'alpha': {'type': 'object', 'properties': {'z': {'type': 'number'}, 'a': {'type': 'boolean'}}},
        'middle': {'items': {'properties': {'last': {}, 'first': {}}, 'type': 'object'}, 'type': 'array'}},
    'type': 'object'}}
REQUEST = {'model': 'synthetic-order', 'tools': [SCHEMA], 'input': 'synthetic',
           'prompt_cache_key': 'synthetic-cache', 'client_metadata': {'z': 'synthetic', 'a': 'synthetic'},
           'reasoning': {'summary': None, 'synthetic_future_option': None, 'effort': 'low'},
           'parallel_tool_calls': None}
RESPONSE = {'synthetic_z': {'z': 1, 'a': {'y': 2, 'b': 3}}, 'id': 'resp_synthetic_order',
            'object': 'response', 'status': 'completed', 'output': [],
            'usage': {'output_tokens_details': {'reasoning_tokens': 1, 'unknown': 7},
                      'output_tokens': 3, 'input_tokens_details': {'cache_write_tokens_details': {'ttl_12h_tokens': 2, 'unknown': 7, 'ttl_30m_tokens': 1}, 'cache_write_tokens': 3, 'cached_tokens': 0},
                      'input_tokens': 5, 'total_tokens': 8}}
COMPACT = {'synthetic_z': {'z': 1, 'a': 2}, 'object': 'response.compaction',
           'id': 'cmp_synthetic_order', 'output': [], 'usage': {'input_tokens': 5, 'output_tokens': 3}}
EVENT = {'synthetic_z': {'z': 1, 'a': 2}, 'type': 'response.completed', 'response': RESPONSE}
RETRY_DATE = 'Wed, 21 Oct 2015 07:28:00 GMT'
PRIVATE_HEADER = 'synthetic-private-header'
PROVIDER_ERROR = {'code': 'rate_limit_exceeded', 'message': 'Synthetic rate limit'}
HEADERS = {'session-id': 'synthetic-stable-session', 'x-codex-turn-metadata': 'synthetic-stable-turn'}


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def capture(self, body, route):
        assert self.headers.get('Authorization') is None
        selected = {key: self.headers.get(key) for key in HEADERS}
        with self.server.guard:
            self.server.captured.append((route, body, selected))
            self.server.guard.notify_all()

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.capture(body, self.path)
        request = json.loads(body)
        compact = self.path.endswith('/compact')
        fault = request.get('synthetic_fault')
        status = 200
        data = wire(COMPACT if compact else RESPONSE)
        mime = 'application/json'
        if not compact and request.get('stream'):
            data = b'data: ' + wire(EVENT) + b'\n\n'
            mime = 'text/event-stream'
        if fault == 'http-retry':
            status, mime = 429, 'application/json'
            data = wire({'error': PROVIDER_ERROR})
        if fault == 'sse-retry':
            created = {'type': 'response.created', 'response': {**RESPONSE, 'status': 'in_progress'}}
            failure = {'type': 'error', 'status': 429, 'error': PROVIDER_ERROR,
                       'headers': {'Retry-After': '12', 'set-cookie': PRIVATE_HEADER}}
            data = b''.join(b'data: ' + wire(event) + b'\n\n' for event in (created, failure))
        self.send_response(status)
        self.send_header('openai-model', 'invalid,model' if fault == 'model-invalid' else 'synthetic-actual-model')
        self.send_header('X-Models-Etag', PRIVATE_HEADER)
        self.send_header('Set-Cookie', PRIVATE_HEADER)
        if fault == 'model-duplicate':
            self.send_header('OpenAI-Model', 'synthetic-second-model')
        if fault == 'model-hop':
            self.send_header('Connection', 'close, OpenAI-Model')
        if fault == 'http-retry':
            self.send_header('Retry-After', RETRY_DATE)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.headers.get('x-codex-synthetic-upgrade') == 'reject':
            self.send_response(429)
            self.send_header('Content-Length', '0')
            self.send_header('Retry-After', RETRY_DATE)
            self.send_header('Set-Cookie', PRIVATE_HEADER)
            self.end_headers()
            return
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
                self.capture(body, 'websocket')
                request = json.loads(body)
                if request.get('synthetic_fault') == 'ws-retry':
                    send(self.connection, wire({
                        'type': 'error', 'status': 429, 'error': PROVIDER_ERROR,
                        'headers': {'Retry-After': '0', 'set-cookie': PRIVATE_HEADER},
                    }))
                elif request.get('synthetic_fault') == 'ws-terminal-retry':
                    error = {**PROVIDER_ERROR, 'headers': {'Retry-After': RETRY_DATE,
                                                          'set-cookie': PRIVATE_HEADER}}
                    send(self.connection, wire({'type': 'response.failed',
                         'response': {**RESPONSE, 'status': 'failed', 'error': error}}))
                elif request.get('synthetic_fault') == 'ws-conflicting-retry':
                    error = {**PROVIDER_ERROR, 'headers': {'Retry-After': '50', 'retry-after': '80'}}
                    send(self.connection, wire({
                        'type': 'error', 'status': 429, 'error': error,
                        'headers': {'Retry-After': '12\n', 'set-cookie': PRIVATE_HEADER},
                    }))
                elif request.get('type') == 'response.create':
                    send(self.connection, wire(EVENT))
                else:
                    # Unknown, non-generating controls pass through byte-for-byte.
                    send(self.connection, b'{"type":"synthetic.ack","z":{"y":1,"a":2}}')
        except (OSError, EOFError):
            return


def call_http(port, route, payload, *, status=200):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    connection.request('POST', '/v1/responses' + ('/compact' if route == 'compact' else ''),
                       body=wire(payload), headers={'Authorization': 'Bearer ' + TOKEN,
                                                    'Content-Type': 'application/json', **HEADERS})
    response = connection.getresponse()
    body = response.read()
    assert response.status == status, (response.status, body)
    headers = {name.lower(): value for name, value in response.getheaders()}
    connection.close()
    return body, headers


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    server.guard = threading.Condition()
    server.captured = []
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    expected_response = json.loads(wire(RESPONSE))
    expected_event = {**EVENT, 'response': expected_response}
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-json-order-') as temporary:
            for contract in ('responses', 'codex-subscription'):
                for transport in ('http', 'websocket'):
                    root = Path(temporary) / (contract + '-' + transport)
                    root.mkdir(mode=0o700)
                    config = root / 'identity.json'
                    config.write_text(json.dumps(dict(principal='synthetic-order', keyID='synthetic-key',
                        keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-order',
                        identity='synthetic-identity', models=[dict(id='synthetic-order', inputMicrosPerMillion=0,
                        outputMicrosPerMillion=0)], reservedMicros=1,
                        upstreamBaseURL=f'http://127.0.0.1:{server.server_port}/v1',
                        upstreamTransport=transport, upstreamContract=contract)))
                    config.chmod(0o600)
                    baseline = {}
                    # Same temporary ledger and configuration, new gateway process/hash seed.
                    for restart in range(2):
                        process, ports = start(str(args.binary.resolve()), config, root)
                        try:
                            routes = ['json', 'sse', 'compact'] + (['native'] if transport == 'websocket' else [])
                            for route in routes:
                                for repeat in range(3):
                                    request = {**REQUEST, 'stream': route in ('sse', 'native')}
                                    before = len(server.captured)
                                    if route == 'native':
                                        with dial(ports['data'], headers=HEADERS) as client:
                                            send(client, wire({'type': 'response.create', **request}), masked=True)
                                            opcode, body = receive(client)
                                            assert opcode == 1 and body == wire(expected_event), body
                                            control = b'{"type":"synthetic.control","z":{"y":1,"a":2},"a":0}'
                                            send(client, control, masked=True)
                                            with server.guard:
                                                assert server.guard.wait_for(lambda: len(server.captured) >= before + 2, timeout=3)
                                                assert server.captured[-1][1] == control
                                    else:
                                        body, reply_headers = call_http(ports['data'], route, request)
                                        assert reply_headers.get('openai-model') == (
                                            'synthetic-actual-model'
                                            if transport == 'http' and route != 'compact' else None)
                                        assert 'x-models-etag' not in reply_headers and 'set-cookie' not in reply_headers
                                        if route == 'compact':
                                            assert body == wire(COMPACT), body
                                        elif route == 'sse':
                                            lines = [line[6:] for line in body.splitlines() if line.startswith(b'data: ') and line != b'data: [DONE]']
                                            assert lines == [wire(expected_event)], body
                                        else:
                                            assert body == wire(expected_response), body
                                    captured_route, raw, headers = server.captured[before]
                                    assert headers == HEADERS, headers
                                    expected = {**request, 'reasoning': {'synthetic_future_option': None, 'effort': 'low'}}
                                    del expected['parallel_tool_calls']
                                    if route != 'compact':
                                        if contract == 'codex-subscription':
                                            expected['store'] = False
                                            expected['stream'] = True
                                            expected['input'] = [{'role': 'user', 'content': 'synthetic'}]
                                        if transport == 'websocket':
                                            if contract == 'responses':
                                                del expected['stream']
                                            expected['type'] = 'response.create'
                                    assert raw == wire(expected), (contract, transport, route, raw, wire(expected))
                                    assert wire(SCHEMA) in raw
                                    if route in baseline:
                                        assert raw == baseline[route], (restart, repeat, route)
                                    else:
                                        baseline[route] = raw
                            if restart == 0 and transport == 'http':
                                for fault in ('model-duplicate', 'model-hop', 'model-invalid'):
                                    _, reply_headers = call_http(ports['data'], 'json', {**REQUEST, 'synthetic_fault': fault})
                                    assert 'openai-model' not in reply_headers, reply_headers
                                before = len(server.captured)
                                _, reply_headers = call_http(
                                    ports['data'], 'json', {**REQUEST, 'synthetic_fault': 'http-retry'}, status=429)
                                assert reply_headers['retry-after'] == RETRY_DATE
                                assert 'openai-model' not in reply_headers and 'set-cookie' not in reply_headers
                                body, _ = call_http(ports['data'], 'sse', {
                                    **REQUEST, 'stream': True, 'synthetic_fault': 'sse-retry'})
                                events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: {')]
                                assert events[-1]['type'] == 'response.failed'
                                assert events[-1]['response']['error']['headers'] == {'retry-after': '12'}
                                assert PRIVATE_HEADER.encode() not in body and len(server.captured) == before + 2
                            if restart == 0 and transport == 'websocket':
                                before = len(server.captured)
                                body, reply_headers = call_http(
                                    ports['data'], 'json', {**REQUEST, 'synthetic_fault': 'ws-retry'}, status=429)
                                assert reply_headers['retry-after'] == '0' and PRIVATE_HEADER.encode() not in body
                                assert len(server.captured) == before + 1
                                with dial(ports['data'], headers={'x-codex-synthetic-upgrade': 'reject'}) as client:
                                    send(client, wire({'type': 'response.create', **REQUEST, 'stream': True}), masked=True)
                                    opcode, body = receive(client)
                                assert opcode == 1 and PRIVATE_HEADER.encode() not in body
                                event = json.loads(body)
                                assert event['type'] == 'error' and event['status'] == 429
                                assert event['headers'] == {'retry-after': RETRY_DATE}
                                assert len(server.captured) == before + 1
                                for fault in ('ws-retry', 'ws-terminal-retry', 'ws-conflicting-retry'):
                                    before = len(server.captured)
                                    with dial(ports['data'], headers=HEADERS) as client:
                                        send(client, wire({'type': 'response.create', **REQUEST,
                                                          'stream': True, 'synthetic_fault': fault}), masked=True)
                                        opcode, body = receive(client)
                                    assert opcode == 1 and PRIVATE_HEADER.encode() not in body
                                    event = json.loads(body)
                                    if fault == 'ws-terminal-retry':
                                        assert event['type'] == 'response.failed'
                                        assert event['response']['error']['headers'] == {'retry-after': RETRY_DATE}
                                    elif fault == 'ws-retry':
                                        assert event['type'] == 'error' and event['status'] == 429
                                        assert event['headers'] == {'retry-after': '0'}
                                    else:
                                        assert event['type'] == 'error' and event['status'] == 429
                                        assert 'headers' not in event and 'headers' not in event['error']
                                    assert len(server.captured) == before + 1
                        finally:
                            stop(process)
                    print(f'PASS: ordered raw bytes {contract}/{transport}: repeat + restart, nested schema, client responses, controls', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(10)


if __name__ == '__main__':
    main()
