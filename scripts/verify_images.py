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
import struct
import subprocess
import tempfile
import threading
import time
from verify_protocol import start, stop, latest
from verify_keys import ADMIN, LIMITS, call
from verify_websocket import dial, send, receive

PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg=='
URL = 'data:image/png;base64,' + PNG

def native_body(prompt):
    if prompt == 'non-json': return b'synthetic invalid JSON'
    document = {'created':1,'data':[] if prompt == 'empty' else [{'b64_json':PNG}], 'future':'preserved'}
    if prompt != 'missing-usage':
        document['usage'] = {'input_tokens':2,'output_tokens':3,'input_tokens_details':{'text_tokens':1,'image_tokens':1}}
    return json.dumps(document).encode()


def native_stream(operation, prompt='synthetic'):
    prefix = 'image_edit' if operation == 'edits' else 'image_generation'
    preview = {'type':prefix+'.partial_image','b64_json':PNG, 'partial_image_index':0}
    final = {'type':prefix+'.completed','b64_json':PNG,'usage':{'input_tokens':2,'output_tokens':3}}
    if prompt == 'stream-empty': final['b64_json'] = ''
    if prompt == 'stream-abort': return b': synthetic comment\r\n\r\ndata: ' + json.dumps(preview).encode() + b'\n\n'
    if prompt == 'stream-error': final = {'type':'error','error':{'code':'synthetic_provider_error','message':'synthetic'}}
    return b': synthetic comment\r\n\r\ndata: ' + json.dumps(preview).encode() + b'\n\nevent: ' + final['type'].encode() + b'\r\ndata: ' + json.dumps(final).encode() + b'\r\n\r\ndata: [DONE]\n\n'


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_args): pass
    def handle(self):
        try: super().handle()
        except (ConnectionResetError, BrokenPipeError): pass
    def events(self, request):
        assert request['model'] in ('synthetic-host', 'synthetic-host-other')
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        tools = request.get('tools', [])
        for tool in tools:
            if tool['type'] == 'image_generation':
                assert 'user' not in tool and 'detail' not in tool
                assert 'detail' not in tool.get('input_image_mask', {})
        for row in request.get('input', []) if isinstance(request.get('input'), list) else []:
            for part in row.get('content', []) if isinstance(row.get('content'), list) else []:
                assert 'detail' not in part
        image = any(t['type'] == 'image_generation' for t in tools) and request.get('tool_choice') != 'none' and request.get('input') != 'no-image'
        item = {'id': f'ig_{index}', 'type': 'image_generation_call', 'status': 'completed', 'result': PNG,
                'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5, 'input_tokens_details': {'text_tokens': 1, 'image_tokens': 1}}}
        prompt = request['input']
        if isinstance(prompt, list):
            prompt = next((part['text'] for row in prompt for part in row.get('content', []) if isinstance(part, dict) and part['type'] == 'input_text'), '')
        if prompt == 'invalid-usage': item['usage']['output_tokens'] = -1
        if prompt == 'missing-usage': item.pop('usage')
        if prompt == 'stall': time.sleep(11)
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
        if prompt == 'invalid-usage':
            # Deliver trusted host usage in the same terminal that contains invalid tool usage.
            # An earlier invalid item may correctly cancel before any host evidence arrives.
            events = events[:1]
        return events + [{'type': 'response.' + response['status'], 'response': response, **lane}]
    def do_POST(self):
        if self.path.startswith('/backend-api/codex/images/'):
            data = self.rfile.read(int(self.headers['Content-Length']))
            request = json.loads(data)
            with self.server.guard:
                self.server.calls += 1
                self.server.requests.append((self.path, data, dict((k.lower(),v) for k,v in self.headers.items())))
            prompt = request.get('prompt','')
            if prompt == 'hold': self.server.release.wait(55)
            status = int(prompt[4:]) if prompt.startswith('http') else 200
            body = (json.dumps({'error':{'code':'synthetic_provider_error','message':'synthetic acct-private'}}).encode()
                if status != 200 else native_stream(self.path.rsplit('/',1)[1], prompt) if request.get('stream') else native_body(prompt))
            if prompt == 'oversize': body = b' ' * (48 * 1024 * 1024 + 1)
            self.send_response(status)
            self.send_header('Content-Type','text/event-stream' if request.get('stream') else 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('x-codex-imagegen-request-id','synthetic-image-request')
            if status == 429: self.send_header('Retry-After','1')
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        length = int(self.headers['Content-Length'])
        assert length <= 34603008 and self.path in ('/v1/responses', '/v1/responses/compact')
        request = json.loads(self.rfile.read(length))
        events = self.events(request)
        if self.path.endswith('/compact'):
            events[-1]['response'] = {'id': 'cmp_' + events[-1]['response']['id'],
                'object': 'response.compaction', 'output': [{'type': 'compaction', 'encrypted_content': 'synthetic-compact'}],
                'usage': events[-1]['response']['usage']}
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

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--browser', action='store_true')
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    upstream = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    upstream.daemon_threads = True
    upstream.guard = threading.Lock()
    upstream.calls = 0
    upstream.requests = []
    upstream.release = threading.Event()
    worker = threading.Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    try:
        for transport in ('http', 'websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-images-') as temporary:
                root = Path(temporary)
                config = root / 'identity.json'
                admin = root / 'admin'; admin.write_text(ADMIN); admin.chmod(0o600)
                token = root / 'upstream-token'; token.write_text('synthetic-upstream-token-for-images'); token.chmod(0o600)
                config.write_text(json.dumps({'managedKeys': True, 'namespace': 'synthetic', 'identity': 'synthetic-account',
                    'reservedMicros': 10, 'executionTimeoutSeconds': 60, 'firstResponseTimeoutSeconds': 60,
                    'upstreamTransport': transport, 'imageConcurrency': 1, 'upstreamTokenFile': str(token),
                    'upstreamBaseURL': f'http://127.0.0.1:{upstream.server_port}/v1',
                    'models': [{'id': 'synthetic-host', 'imageGeneration': True, 'visionInput': True,
                        'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000}],
                    'imageGeneration': {'defaultModel': 'synthetic-image', 'models': [{'id': 'synthetic-image',
                        'inputMicrosPerMillion': 2000000, 'outputMicrosPerMillion': 3000000}]}}))
                config.chmod(0o600)
                process, ports = start(str(args.binary.resolve()), config, root, admin_token_file=admin,
                    web_directory=(repository / 'web/dist').resolve() if args.browser else None)
                try:
                    policies = {}
                    for name, image in [('images', True), ('chat', False), ('both', True)]:
                        status, created = call(ports['admin'], 'POST', '/api/keys', dict(principal='team',
                            models=[] if name == 'images' else ['synthetic-host'], limits={**LIMITS, 'unresolved': 100},
                            visionInput=name == 'both', imageGeneration=image,
                            imageModels=['synthetic-image'] if image else []))
                        assert status == 201, (status, created)
                        policies[name] = created
                    port = ports['data']; db = root / 'state/core.sqlite'
                    def request(body, path='/v1/images/generations', name='images', headers=None, content_type='application/json'):
                        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=65)
                        connection.request('POST', path, body if isinstance(body, bytes) else json.dumps(body).encode(),
                            {'Authorization': 'Bearer ' + policies[name]['secret'], 'Content-Type': content_type, **(headers or {})})
                        response = connection.getresponse()
                        result = response.status, response.read(), dict((k.lower(), v) for k, v in response.getheaders())
                        connection.close()
                        return result
                    def ledger():
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            with sqlite3.connect(db) as connection:
                                row = connection.execute('SELECT state,usage_json,outcome_json FROM attempts ORDER BY rowid DESC LIMIT 1').fetchone()
                            if row and row[0] != 'intent':
                                return row[0], json.loads(row[1]) if row[1] else None, json.loads(row[2]) if row[2] else None
                            time.sleep(.02)
                        raise AssertionError('Finalization did not finish')
                    def count_intents():
                        with sqlite3.connect(db) as connection:
                            return connection.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
                    def wait_calls(expected):
                        deadline = time.monotonic() + 5
                        while upstream.calls < expected and time.monotonic() < deadline: time.sleep(.02)
                        assert upstream.calls == expected
                    client_headers = {'x-codex-image-turn-id': 'synthetic-turn', 'x-codex-turn-metadata': '{"synthetic":true}',
                        'User-Agent': 'synthetic-codex-client', 'originator': 'synthetic-desktop', 'version': '1.0',
                        'chatgpt-account-id': 'forged-account', 'x-client-private': 'do-not-forward'}
                    for prefix in ('/v1', '/backend-api/codex'):
                        for operation in ('generations', 'edits'):
                            wire = ('{ "model" : "synthetic-image", "prompt":"synthetic", "n":2, "future":{"x":true}'
                                + (', "images":[{"image_url":"' + URL + '","detail":"preserve"}], "mask":{"image_url":"' + URL + '"}' if operation == 'edits' else '') + ' }').encode()
                            before = upstream.calls
                            status, body, headers = request(wire, prefix + '/images/' + operation, headers=client_headers)
                            assert status == 200 and upstream.calls == before + 1, (status, body[:200])
                            path, received, sent_headers = upstream.requests[-1]
                            assert path == '/backend-api/codex/images/' + operation and received == wire
                            for key in ('x-codex-image-turn-id', 'x-codex-turn-metadata', 'originator', 'version'):
                                assert sent_headers[key] == client_headers[key]
                            assert sent_headers['user-agent'] == client_headers['User-Agent']
                            assert sent_headers['authorization'] == 'Bearer synthetic-upstream-token-for-images'
                            assert 'chatgpt-account-id' not in sent_headers and 'x-client-private' not in sent_headers
                            assert headers['x-codex-imagegen-request-id'] == 'synthetic-image-request'
                            assert headers['x-request-id']
                            assert body == native_body('synthetic')
                            state, usage, outcome = ledger()
                            assert state == 'settled' and outcome['kind'] == 'succeeded'
                            assert usage['images'] == 1 and usage['imageInputTokens'] == 2 and usage['imageOutputTokens'] == 3
                            assert usage['imageInputTextTokens'] == 1 and usage['imageInputImageTokens'] == 1
                            assert usage['estimatedMicros'] == 13
                            status, _, _ = request({'prompt':'default', 'future':42}, prefix + '/images/' + operation)
                            assert status == 200
                            assert json.loads(upstream.requests[-1][1]) == {'prompt':'default','future':42,'model':'synthetic-image'}
                            status, body, _ = request({'prompt':'synthetic','stream':True}, prefix + '/images/' + operation)
                            assert status == 200 and body == native_stream(operation)
                            assert ledger()[0] == 'settled'
                    before = upstream.calls; intents = count_intents()
                    for body, name in [({'model':'synthetic-denied'}, 'images'), ({'prompt':'synthetic'}, 'chat')]:
                        status, error, _ = request(body, name=name)
                        assert status == 403 and json.loads(error)['error']['code'] == 'model_not_allowed'
                    assert upstream.calls == before and count_intents() == intents
                    multipart = b'--synthetic\r\n'
                    for field, value in [('prompt', b'synthetic edit'), ('n', b'3'), ('stream', b'false'), ('future', b'preserved')]:
                        multipart += f'Content-Disposition: form-data; name="{field}"\r\n\r\n'.encode() + value + b'\r\n--synthetic\r\n'
                    for field in ('image[]', 'mask'):
                        multipart += f'Content-Disposition: form-data; name="{field}"; filename="synthetic.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + base64.b64decode(PNG) + b'\r\n--synthetic' + (b'\r\n' if field == 'image[]' else b'--\r\n')
                    assert request(multipart, '/v1/images/edits', content_type='multipart/form-data; boundary=synthetic')[0] == 200
                    assert json.loads(upstream.requests[-1][1]) == {'model':'synthetic-image','prompt':'synthetic edit','n':3,'stream':False,'future':'preserved', 'images':[{'image_url':URL}], 'mask':{'image_url':URL}}
                    assert request(multipart, '/backend-api/codex/images/edits', content_type='multipart/form-data; boundary=synthetic')[0] == 415
                    for fault, expected in [('http400',400), ('http429',429), ('http500',502)]:
                        before = upstream.calls
                        status, error, headers = request({'prompt':fault})
                        assert status == expected and upstream.calls == before + 1, (status,error[:200])
                        assert json.loads(error)['error']['code'] == 'synthetic_provider_error'
                        assert 'acct-private' not in error.decode() and headers['x-request-id']
                        assert headers['x-codex-imagegen-request-id'] == 'synthetic-image-request'
                        if expected == 429: assert headers['retry-after'] == '1'
                        assert ledger()[0] == 'unknown'
                    for fault in ('empty', 'non-json', 'oversize'):
                        status, body, _ = request({'prompt':fault})
                        assert status == (502 if fault == 'oversize' else 200), (fault,status,body[:100])
                        state, usage, outcome = ledger()
                        assert outcome['kind'] == 'failed'
                        if fault != 'empty': assert state == 'unknown'
                    assert request({'prompt':'missing-usage'})[0] == 200
                    state, usage, outcome = ledger()
                    assert state == 'unknown' and usage['completeness'] == 'partial' and 'imageInputTokens' not in usage and 'imageOutputTokens' not in usage
                    assert usage['images'] == 1 and outcome['kind'] == 'succeeded'
                    for fault in ('stream-abort', 'stream-empty', 'stream-error'):
                        status, body, _ = request({'prompt':fault,'stream':True})
                        assert status == 200 and ledger()[2]['kind'] == 'failed'
                    # A held upstream consumes the sole permit. A queued request times out before intent/dispatch.
                    if transport == 'http':
                        upstream.release.clear()
                        before = upstream.calls
                        wire = json.dumps({'prompt':'hold'}).encode()
                        held = socket.create_connection(('127.0.0.1',port), timeout=5)
                        held.sendall(('POST /v1/images/generations HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' + policies['images']['secret'] + '\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(wire)) + '\r\n\r\n').encode() + wire)
                        wait_calls(before + 1)
                        intents = count_intents()
                        started = time.monotonic()
                        status, error, headers = request({'prompt':'waiting'})
                        assert status == 429 and time.monotonic() - started >= 29
                        assert json.loads(error)['error']['code'] == 'image_capacity_exhausted' and headers['retry-after'] == '1'
                        assert upstream.calls == before + 1 and count_intents() == intents
                        held.close()
                        state, usage, outcome = ledger()
                        assert state == 'unknown' and outcome['kind'] == 'cancelled'
                        assert request({'prompt':'released'})[0] == 200
                        assert upstream.calls == before + 2
                        upstream.release.set()
                    # Responses managed tool evidence remains independent from native Images accounting.
                    status, body, _ = request({'model':'synthetic-host','input':'synthetic','tools':[{'type':'image_generation'}]}, '/v1/responses', name='both')
                    assert status == 200, (status,body[:200])
                    state, usage, _ = ledger()
                    assert state == 'settled' and usage['inputTokens'] == 5 and usage['imageInputTokens'] == 2 and usage['estimatedMicros'] == 25
                    if args.browser and transport == 'http':
                        result = subprocess.run(['node', str(repository / 'web/scripts/live-images.mjs'), str(ports['admin']), str(port), str(repository / 'artifacts/image-management-ui')], input=json.dumps({'credential': ADMIN}).encode(), capture_output=True, timeout=60)
                        assert result.returncode == 0, 'Image browser validation failed; private output withheld'
                    print('PASS: native Images byte/header/path parity, multipart, usage, SSE, provider failures, unknown/no replay and capacity via ' + transport)
                finally:
                    upstream.release.set()
                    stop(process)
    finally:
        upstream.release.set()
        upstream.shutdown(); upstream.server_close(); worker.join(timeout=3)

if __name__ == '__main__': main()
