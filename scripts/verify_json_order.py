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
           'reasoning': {'summary': None, 'effort': 'low'}, 'parallel_tool_calls': None}
RESPONSE = {'synthetic_z': {'z': 1, 'a': {'y': 2, 'b': 3}}, 'id': 'resp_synthetic_order',
            'object': 'response', 'status': 'completed', 'output': [],
            'usage': {'output_tokens_details': {'reasoning_tokens': 1, 'unknown': 7},
                      'output_tokens': 3, 'input_tokens_details': {'cache_write_tokens': 1, 'cached_tokens': 0},
                      'input_tokens': 5, 'total_tokens': 8}}
COMPACT = {'synthetic_z': {'z': 1, 'a': 2}, 'object': 'response.compaction',
           'id': 'cmp_synthetic_order', 'output': [], 'usage': {'input_tokens': 5, 'output_tokens': 3}}
EVENT = {'synthetic_z': {'z': 1, 'a': 2}, 'type': 'response.completed', 'response': RESPONSE}
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
        data = wire(COMPACT if compact else RESPONSE)
        mime = 'application/json'
        if not compact and request.get('stream'):
            data = b'data: ' + wire(EVENT) + b'\n\n'
            mime = 'text/event-stream'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
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
                if json.loads(body).get('type') == 'response.create':
                    send(self.connection, wire(EVENT))
                else:
                    # Unknown, non-generating controls pass through byte-for-byte.
                    send(self.connection, b'{"type":"synthetic.ack","z":{"y":1,"a":2}}')
        except (OSError, EOFError):
            return


def call_http(port, route, payload):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    connection.request('POST', '/v1/responses' + ('/compact' if route == 'compact' else ''),
                       body=wire(payload), headers={'Authorization': 'Bearer ' + TOKEN,
                                                    'Content-Type': 'application/json', **HEADERS})
    response = connection.getresponse()
    body = response.read()
    assert response.status == 200, (response.status, body)
    connection.close()
    return body


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
    del expected_response['usage']['output_tokens_details']['unknown']
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
                                        body = call_http(ports['data'], route, request)
                                        if route == 'compact':
                                            assert body == wire(COMPACT), body
                                        elif route == 'sse':
                                            lines = [line[6:] for line in body.splitlines() if line.startswith(b'data: ') and line != b'data: [DONE]']
                                            assert lines == [wire(expected_event)], body
                                        else:
                                            assert body == wire(expected_response), body
                                    captured_route, raw, headers = server.captured[before]
                                    assert headers == HEADERS, headers
                                    expected = {**request, 'reasoning': {'effort': 'low'}}
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
                        finally:
                            stop(process)
                    print(f'PASS: ordered raw bytes {contract}/{transport}: repeat + restart, nested schema, client responses, controls', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(10)


if __name__ == '__main__':
    main()
