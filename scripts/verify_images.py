#!/usr/bin/env python3
"""M4 real synthetic HTTP/SSE/multipart/WS and SQLite checks. No external credentials."""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
from verify_protocol import start, stop, latest
from verify_keys import ADMIN, LIMITS, call
from verify_websocket import dial, send, receive

PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg=='
URL = 'data:image/png;base64,' + PNG

class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def handle(self):
        try: super().handle()
        except (ConnectionResetError, BrokenPipeError): pass
    def events(self, request):
        assert request['model'] == 'synthetic-host'
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        tools = request.get('tools', [])
        image = any(t['type'] == 'image_generation' for t in tools) and request.get('tool_choice') != 'none' and request.get('input') != 'no-image'
        item = {'id': f'ig_{index}', 'type': 'image_generation_call', 'status': 'completed', 'result': PNG,
                'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5, 'input_tokens_details': {'text_tokens': 1, 'image_tokens': 1}}}
        prompt = request['input']
        if isinstance(prompt, list):
            prompt = next((part['text'] for row in prompt for part in row.get('content', []) if isinstance(part, dict) and part['type'] == 'input_text'), '')
        if prompt == 'invalid-usage': item['usage']['output_tokens'] = -1
        if prompt == 'missing-usage': item.pop('usage')
        if prompt == 'stall': time.sleep(3)
        response = {'id': f'resp_{index}', 'status': 'completed', 'output': [item] if image else [],
                    'usage': {'input_tokens': 5, 'output_tokens': 7, 'input_tokens_details': {'cached_tokens': 0}}}
        lane = {'stream_id': request['stream_id']} if 'stream_id' in request else {}
        events = [{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': [], 'usage': None}, **lane}]
        if image:
            events += [{'type': 'response.output_item.added', 'item': {**item, 'status': 'in_progress', 'result': None}, **lane},
                       {'type': 'response.image_generation_call.partial_image', 'item_id': item['id'], 'partial_image_index': 0, 'partial_image_b64': PNG, **lane},
                       {'type': 'response.output_item.done', 'item': item, **lane}]
        if prompt in ('failed-empty', 'incomplete-empty'):
            response['status'] = 'failed' if prompt == 'failed-empty' else 'incomplete'
            response['output'] = []
        if prompt == 'failed-after-item':
            response['status'] = 'failed'
        if prompt == 'invalid-output':
            item['result'] = 'bm90LWFuLWltYWdl'
        if prompt == 'abort-after-item': return events
        return events + [{'type': 'response.' + response['status'], 'response': response, **lane}]
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        assert length <= 8388608 and self.path == '/v1/responses'
        request = json.loads(self.rfile.read(length))
        events = self.events(request)
        self.send_response(200)
        streaming = request.get('stream', False)
        body = (''.join('data: ' + json.dumps(event) + '\n\n' for event in events).encode() if streaming
                else json.dumps(events[-1]['response']).encode())
        self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8: return
                for event in self.events(json.loads(data)): send(self.connection, event)
        except (EOFError, OSError): pass


def raw(port, path, data, token, content_type='application/json'):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    connection.request('POST', path, data, {'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
    response = connection.getresponse(); result = response.status, response.read(); connection.close()
    return result


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', type=Path, required=True); parser.add_argument('--browser', action='store_true')
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    upstream = ThreadingHTTPServer(('127.0.0.1', 0), Provider); upstream.daemon_threads = True
    upstream.guard = threading.Lock(); upstream.calls = 0
    worker = threading.Thread(target=upstream.serve_forever, daemon=True); worker.start()
    try:
        for transport in ('http', 'websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-images-') as temporary:
                root = Path(temporary)
                config = root / 'identity.json'; admin = root / 'admin'; admin.write_text(ADMIN); admin.chmod(0o600)
                config.write_text(json.dumps({'managedKeys': True, 'namespace': 'synthetic', 'identity': 'synthetic-account',
                    'reservedMicros': 10, 'executionTimeoutSeconds': 2, 'upstreamTransport': transport,
                    'upstreamBaseURL': f'http://127.0.0.1:{upstream.server_port}/v1',
                    'models': [{'id': host, 'visionInput': True, 'imageGeneration': True, 'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000} for host in ('synthetic-host', 'synthetic-host-other')],
                    'imageGeneration': {'defaultModel': 'synthetic-image', 'models': [{'id': image, 'hostModel': host,
                        'sizePolicy': 'fixed1536', 'supportsTransparency': True, 'supportsInputFidelity': True, 'inputMicrosPerMillion': 2000000, 'outputMicrosPerMillion': 3000000} for image, host in [('synthetic-image', 'synthetic-host'), ('synthetic-image-other', 'synthetic-host-other')]]}}))
                config.chmod(0o600)
                process, ports = start(str(args.binary.resolve()), config, root, admin_token_file=admin, web_directory=(repository / 'web/dist').resolve() if args.browser else None)
                try:
                    policies = {}
                    for name, models, vision, image in [('chat', ['synthetic-host'], False, False), ('vision', ['synthetic-host'], True, False), ('images', [], False, True), ('both', ['synthetic-host'], True, True), ('other', ['synthetic-host'], True, True), ('cross', ['synthetic-host-other'], True, True)]:
                        status, created = call(ports['admin'], 'POST', '/api/keys', dict(principal=name if name == 'other' else 'team', models=models, limits=LIMITS,
                            visionInput=vision, imageGeneration=image, imageModels=['synthetic-image'] if image else []))
                        assert status == 201, (status, created)
                        policies[name] = created
                    port = ports['data']; db = root / 'state/core.sqlite'
                    def request(name, endpoint, body): return raw(port, endpoint, json.dumps(body).encode(), policies[name]['secret'])
                    for prefix in ('/v1', '/backend-api/codex'):
                        for name in ('chat', 'vision'):
                            before = upstream.calls
                            assert request(name, prefix + '/images/generations', {'prompt': 'synthetic'})[0] != 200
                            assert upstream.calls == before
                        status, body = request('images', prefix + '/images/generations', {'prompt': 'synthetic'})
                        assert status == 200 and json.loads(body)['data'][0]['b64_json'] == PNG, (status, body[:200])
                        usage = latest(db, 'settled'); assert usage['images'] == 1 and usage['imageInputTokens'] == 2 and usage['estimatedMicros'] == 25
                        status, body = request('images', prefix + '/images/edits', {'prompt': 'synthetic edit', 'images': [{'image_url': URL}], 'mask': {'image_url': URL}, 'stream': True})
                        assert status == 200 and b'image_edit.partial_image' in body and b'image_edit.completed' in body
                        for line in body.splitlines():
                            if not line.startswith(b'data: ') or line[6:] == b'[DONE]': continue
                            event = json.loads(line[6:])
                            if event['type'] in ('image_edit.partial_image', 'image_edit.completed'):
                                assert all(name in event for name in ('created_at', 'size', 'quality', 'background', 'output_format'))
                                assert event['output_format'] == 'png' and event['created_at'] > 0
                        status, body = request('images', prefix + '/images/edits', {'prompt': 'next active edit', 'images': [{'image_url': URL}]})
                        assert status == 200
                    multipart = (b'--synthetic\r\nContent-Disposition: form-data; name="prompt"\r\n\r\nsynthetic edit\r\n--synthetic\r\nContent-Disposition: form-data; name="image[]"; filename="synthetic.png"\r\nContent-Type: image/png\r\n\r\n' + base64.b64decode(PNG) + b'\r\n--synthetic--\r\n')
                    assert raw(port, '/v1/images/edits', multipart, policies['images']['secret'], 'multipart/form-data; boundary=synthetic')[0] == 200
                    vision = {'model': 'synthetic-host', 'input': [{'role': 'user', 'content': [{'type': 'input_image', 'image_url': URL}]}]}
                    assert request('vision', '/v1/responses', vision)[0] == 200
                    assert request('chat', '/v1/responses', vision)[0] != 200
                    status, directory = call(port, 'GET', '/v1/models', token=policies['cross']['secret'])
                    assert status == 200 and next(model for model in directory['data'] if model['id'] == 'synthetic-host-other')['image_generation'] is False
                    before = upstream.calls
                    assert request('cross', '/v1/responses', {'model': 'synthetic-host-other', 'input': 'synthetic', 'tools': [{'type': 'image_generation', 'model': 'synthetic-image-other'}]})[0] == 403
                    assert upstream.calls == before
                    tool = {'model': 'synthetic-host', 'input': 'synthetic', 'tools': [{'type': 'image_generation'}]}
                    for zero in ({**tool, 'tool_choice': 'none'}, {**tool, 'input': 'no-image'}):
                        assert request('both', '/v1/responses', zero)[0] == 200
                        usage = latest(db, 'settled'); assert usage['images'] == 0 and usage['imageInputTokens'] == 0 and usage['estimatedMicros'] == 12
                    assert request('chat', '/v1/responses', tool)[0] != 200
                    assert request('images', '/v1/responses', tool)[0] != 200
                    status, body = request('both', '/v1/responses', tool); assert status == 200, (status, body[:200])
                    result = json.loads(body)
                    follow = {**tool, 'input': [{'type': 'image_generation_call', 'id': result['output'][0]['id']}, {'role': 'user', 'content': 'synthetic next edit'}]}
                    assert request('both', '/v1/responses', follow)[0] == 200
                    before = upstream.calls
                    assert request('other', '/v1/responses', follow)[0] != 200
                    assert upstream.calls == before
                    for prompt in ('failed-after-item', 'abort-after-item', 'invalid-output'):
                        before = upstream.calls
                        status, body = request('images', '/v1/images/generations', {'prompt': prompt, 'stream': True})
                        assert b'image_generation.completed' not in body, (prompt, status, body[:100])
                        assert upstream.calls == before + 1
                    for prompt in ('failed-empty', 'incomplete-empty'):
                        status, body = request('images', '/v1/images/generations', {'prompt': prompt, 'stream': True})
                        assert b'image_generation.completed' not in body
                        partial = latest(db, 'unknown'); assert partial['completeness'] == 'partial' and 'imageInputTokens' not in partial
                    status, _ = request('images', '/v1/images/generations', {'prompt': 'invalid-usage'})
                    assert status == 502
                    invalid_usage = latest(db, 'unknown'); assert invalid_usage['inputTokens'] == 5 and invalid_usage['estimatedMicros'] == 12
                    before = upstream.calls
                    status, _ = request('images', '/v1/images/generations', {'prompt': 'stall'})
                    assert status == 504 and upstream.calls == before + 1
                    assert request('images', '/v1/images/generations', {'prompt': 'missing-usage'})[0] == 200
                    usage = latest(db, 'unknown'); assert usage['completeness'] == 'partial' and 'imageInputTokens' not in usage
                    before = upstream.calls
                    for body in ({'prompt': 'synthetic', 'model': 123}, {'prompt': 'synthetic', 'model': None}, {'prompt': 'synthetic', 'n': 2}, {'prompt': 'synthetic', 'size': '4096x4096'}, {'prompt': 'synthetic', 'images': [{'image_url': 'https://example.invalid/x.png'}]}):
                        assert request('images', '/v1/images/edits' if 'images' in body else '/v1/images/generations', body)[0] == 400
                    assert upstream.calls == before
                    # Authentication and declared size are checked before waiting for an oversized body.
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
                        sock.sendall(b'POST /v1/images/edits HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9000000\r\n\r\n')
                        assert b'401' in sock.recv(4096)
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
                        sock.sendall(('POST /v1/images/edits HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' + policies['images']['secret'] + '\r\nContent-Length: 9000000\r\n\r\n').encode())
                        assert b'413' in sock.recv(4096)
                    if transport == 'websocket':
                        with dial(port, token=policies['both']['secret']) as sock:
                            send(sock, {'type': 'response.create', **tool}, masked=True)
                            events = []
                            while True:
                                opcode, data = receive(sock); assert opcode == 1
                                event = json.loads(data); events.append(event)
                                if event['type'] == 'response.completed': break
                            assert any(e['type'] == 'response.image_generation_call.partial_image' for e in events)
                            key = policies['both']['key']
                            status, _ = call(ports['admin'], 'PUT', '/api/keys/' + key['id'], dict(revision=key['revision'], enabled=True, models=key['models'], limits=key['limits'], visionInput=True, imageGeneration=False, imageModels=['synthetic-image']))
                            assert status == 200
                            before = upstream.calls
                            send(sock, {'type': 'response.create', **tool}, masked=True)
                            opcode, denied = receive(sock)
                            assert opcode == 1 and json.loads(denied)['type'] == 'error' and upstream.calls == before
                    if args.browser and transport == 'http':
                        result = subprocess.run(['node', str(repository / 'web/scripts/live-images.mjs'), str(ports['admin']), str(port), str(repository / 'artifacts/image-management-ui')], input=json.dumps({'credential': ADMIN}).encode(), capture_output=True, timeout=60)
                        assert result.returncode == 0, 'Image browser validation failed; private output withheld'
                    with sqlite3.connect(db) as connection:
                        for admission, in connection.execute("SELECT admission_json FROM attempts WHERE json_extract(admission_json,'$.requirements.route')='images'"):
                            assert json.loads(admission)['model'] == 'synthetic-image'
                        assert connection.execute('PRAGMA user_version').fetchone()[0] == 6
                    with sqlite3.connect(db) as connection:
                        connection.execute("CREATE TRIGGER synthetic_binding_failure BEFORE INSERT ON bindings BEGIN SELECT RAISE(ABORT,'synthetic'); END")
                    before = upstream.calls
                    status, body = request('images', '/v1/images/generations', {'prompt': 'synthetic binding failure'})
                    assert status == 503 and b'b64_json' not in body and upstream.calls == before + 1
                    assert (latest(db, 'settled')['images'] == 1) if transport == 'http' else (latest(db, 'unknown') is None)
                    print('PASS: Images JSON/SSE/multipart, active edits, permission/ownership, usage, failures and no replay via ' + transport)
                finally: stop(process)
    finally:
        upstream.shutdown(); upstream.server_close(); worker.join(timeout=3)

if __name__ == '__main__': main()
