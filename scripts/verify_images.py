#!/usr/bin/env python3
"""M4 real synthetic HTTP/SSE/multipart/WS and SQLite checks. No external credentials."""
import argparse
from concurrent.futures import ThreadPoolExecutor
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
OUTPUTS = {'png': PNG,
    # Synthetic 2×1 animation, red for 100 ms and blue for 200 ms.
    'gif': ('R0lGODlhAgABAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgABAAAIBQABAAgI'
            'ACH5BAEUAAEALAAAAAACAAEAgQAA/wAAAAAAAAAAAAgFAAEACAgAOw=='),
    'svg': base64.b64encode(b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>').decode(),
    'synthetic-future': base64.b64encode(b'synthetic-future-output-container').decode()}
GIF_ANIMATION = {'frame_count': 2, 'frame_duration_ms': 200}


def native_body(prompt, output_format='png'):
    if prompt == 'non-json': return b'synthetic invalid JSON'
    if prompt == 'wrong-native-format': output_format = 'png'
    document = {'created':1,'data':[] if prompt == 'empty' else [{'b64_json':OUTPUTS.get(output_format, PNG)}], 'future':'preserved'}
    if prompt == 'synthetic': document['service_tier'] = 'default'
    if prompt != 'missing-usage':
        document['usage'] = {'input_tokens':2,'output_tokens':3,'input_tokens_details':{'text_tokens':1,'image_tokens':1}}
    return json.dumps(document).encode()


def native_stream(operation, prompt='synthetic', output_format='png'):
    prefix = 'image_edit' if operation == 'edits' else 'image_generation'
    preview = {'type':prefix+'.partial_image','b64_json':OUTPUTS.get(output_format, PNG), 'partial_image_index':0}
    final = {'type':prefix+'.completed','created_at':1,'b64_json':OUTPUTS.get(output_format, PNG),'future':'preserved',
        'usage':{'input_tokens':2,'output_tokens':3,'input_tokens_details':{'text_tokens':1,'image_tokens':1}}}
    if prompt in ('author-stream-missing', 'author-stream-decrease'):
        final['svg_usage'] = {'model':'synthetic-author', 'input_tokens':10, 'output_tokens':20}
        final['image_index'] = 0
        second = {**final, 'image_index':1}
        if prompt == 'author-stream-missing': second.pop('svg_usage')
        else: second['svg_usage'] = {'model':'synthetic-author', 'input_tokens':1, 'output_tokens':2}
        return b''.join(b'data: ' + json.dumps(event).encode() + b'\n\n' for event in (final, second))
    if prompt == 'missing-usage': final.pop('usage')
    if prompt == 'stream-missing-created': final.pop('created_at')
    if prompt == 'synthetic': final['service_tier'] = 'default'
    if prompt == 'stream-empty': final['b64_json'] = ''
    if prompt == 'stream-mixed': final['data'] = [{'b64_json':PNG}, {'b64_json':'invalid'}]
    if prompt.startswith('stream-status-'): final['status'] = prompt.removeprefix('stream-status-')
    if prompt == 'stream-error-explicit': final = {'type':'error','status':422,'error':{'type':'invalid_request_error','code':'synthetic_provider_error'}}
    if prompt == 'stream-abort': return b': synthetic comment\r\n\r\ndata: ' + json.dumps(preview).encode() + b'\n\n'
    if prompt == 'stream-error': final = {'type':'error','error':{'code':'synthetic_provider_error','message':'synthetic acct-split-secret user-synthetic@example.invalid',
        'type':'invalid_request_error','param':'prompt','private':'synthetic-private-member'}}
    result = b': synthetic comment\r\n\r\ndata: ' + json.dumps(preview).encode() + b'\n\nevent: ' + final['type'].encode() + b'\r\ndata: ' + json.dumps(final).encode() + b'\r\n\r\n'
    if prompt in ('stream-multiple', 'stream-multiple-repeated', 'stream-multiple-late', 'stream-multiple-malformed', 'stream-multiple-duplicate-index'):
        first = dict(final)
        first['image_index'] = 0
        if prompt == 'stream-multiple-late': first.pop('usage')
        second = {**final, 'image_index':1, 'b64_json':base64.b64encode(b'synthetic-second-image').decode()}
        if prompt == 'stream-multiple-repeated': second['b64_json'] = PNG
        if prompt != 'stream-multiple-repeated':
            second['usage'] = {'input_tokens':4, 'output_tokens':7, 'input_tokens_details':{'text_tokens':2, 'image_tokens':2}}
        if prompt == 'stream-multiple-malformed': second['b64_json'] = 'invalid'
        if prompt == 'stream-multiple-duplicate-index': second['image_index'] = 0
        result = b''.join(b'data: ' + json.dumps(e).encode() + b'\n\n' for e in (first,second))
    if prompt == 'stream-duplicate': result += b'data: ' + json.dumps(final).encode() + b'\n\n'
    if prompt == 'stream-tail': return result + b'data: {'
    return result + b'data: [DONE]\n\n'


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
        output_format = next((t.get('output_format', 'png') for t in tools if t['type'] == 'image_generation'), 'png')
        item['result'] = OUTPUTS.get(output_format, PNG)
        prompt = request['input']
        if isinstance(prompt, list):
            prompt = next((part['text'] for row in prompt for part in row.get('content', []) if isinstance(part, dict) and part['type'] == 'input_text'), '')
        if prompt == 'invalid-usage': item['usage']['output_tokens'] = -1
        if prompt == 'missing-usage': item.pop('usage')
        if prompt == 'stall': time.sleep(11)
        response = {'id': f'resp_{index}', 'status': 'completed', 'output': [item] if image else [],
                    'usage': {'input_tokens': 5, 'output_tokens': 7, 'input_tokens_details': {'cached_tokens': 0}}}
        author = {'model':'synthetic-author', 'input_tokens':10, 'output_tokens':20}
        if prompt == 'mixed-invalid-usage':
            response['output'].append({**item, 'id':f'ig_second_{index}', 'usage':{'input_tokens':4, 'output_tokens':-1}})
        if prompt == 'invalid-host-usage':
            response['usage']['input_tokens'] = 'synthetic-bad-counter'
            response['usage']['synthetic_future'] = {'nullable':None, 'large':9007199254740993}
        if prompt == 'svg-root-usage': response['svg_usage'] = author
        if prompt == 'svg-item-usage': item['svg_usage'] = author
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
            item['result'] = 'invalid'
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
            # Exercise the one-response compatibility path when the provider elects SSE.
            sse = request.get('stream') or prompt == 'unknown-native-events' or (
                self.path.endswith('/generations') and prompt.startswith('stream-'))
            body = (json.dumps({'error':{'code':'synthetic_provider_error','message':'synthetic acct-private'}}).encode()
                if status != 200 else native_stream(self.path.rsplit('/',1)[1], prompt, request.get('output_format', 'png')) if sse else native_body(prompt, request.get('output_format', 'png')))
            if prompt == 'stream-error' and not sse:
                status = 400; body = json.dumps({'error':{'code':'synthetic_provider_error', 'type':'invalid_request_error', 'message':'synthetic acct-split-secret user-synthetic@example.invalid', 'param':'prompt'}}).encode()
            if prompt.startswith('json-stream'):
                body = native_body('synthetic')
                if prompt.startswith('json-stream-status-'):
                    result = json.loads(body); result['status'] = prompt.removeprefix('json-stream-status-').removesuffix('-partial')
                    if prompt.endswith('-partial'): result['usage']['output_tokens'] = -1
                    body = json.dumps(result).encode()
                if prompt == 'json-stream-empty': body = native_body('empty')
                if prompt == 'json-stream-invalid': body = b'{'
                if prompt == 'json-stream-mixed':
                    result = json.loads(body); result['data'].append({'b64_json':'invalid'})
                    body = json.dumps(result).encode()
                if prompt == 'json-stream-multiple':
                    result = json.loads(body); result['data'].append({'b64_json':PNG, 'revised_prompt':'synthetic'})
                    body = json.dumps(result).encode()
            if prompt == 'oversize': body = b' ' * (48 * 1024 * 1024 + 1)
            if prompt == 'extended-mixed':
                result = json.loads(native_body('synthetic'))
                result['data'].append({'b64_json':'invalid'})
                body = json.dumps(result).encode()
            if prompt == 'extended-sse': body = native_stream('generations')
            if prompt == 'extended-error': body = b'{"error":{"message":"synthetic"}}'
            if prompt == 'svg-author-usage':
                result = json.loads(native_body('synthetic', request.get('output_format', 'png')))
                result['svg_usage'] = {'model':'synthetic-author', 'input_tokens':10, 'output_tokens':20}
                body = json.dumps(result).encode()
            if prompt == 'unknown-native-events':
                event = b'data: {"type":"image_generation.synthetic_future","future":true}\n\n'
                body = event * 12
            if prompt == 'json-slow': time.sleep(.25)
            self.send_response(status)
            self.send_header('Content-Type', 'text/event-stream' if prompt == 'extended-sse' else ('text/html' if prompt == 'json-stream-html' else 'application/json; charset=utf-8')
                if prompt.startswith('json-stream') else 'text/event-stream' if sse else 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('x-codex-imagegen-request-id','synthetic-image-request')
            if status == 429: self.send_header('Retry-After','1')
            self.end_headers()
            try:
                if prompt == 'unknown-native-events':
                    # Keep sending valid unknown events past first-response expiry.
                    event = b'data: {"type":"image_generation.synthetic_future","future":true}\n\n'
                    for _ in range(12):
                        self.wfile.write(event); self.wfile.flush(); time.sleep(.2)
                elif prompt in ('json-slow', 'json-stalled', 'json-truncated'):
                    split = len(body) // 2
                    self.wfile.write(body[:split]); self.wfile.flush()
                    if prompt == 'json-truncated':
                        self.close_connection = True
                        return
                    time.sleep(1.6 if prompt == 'json-stalled' else .35)
                    self.wfile.write(body[split:])
                elif sse:
                    # Split inside the final event, after sensitive text for errors. Flush and
                    # pause to force the gateway to process the first fragment before the rest.
                    marker = b'acct-split-secret' if prompt == 'stream-error' else b'"usage"'
                    split = body.index(marker) + len(marker) if marker in body else len(body) // 2
                    self.wfile.write(body[:split]); self.wfile.flush()
                    time.sleep(0.15)
                    self.wfile.write(body[split:]); self.wfile.flush()
                else:
                    self.wfile.write(body)
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--browser', action='store_true')
    mode.add_argument('--smoke', action='store_true', help='Run representative native Images wire and settlement checks')
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
                            models=[] if name == 'images' else ['synthetic-host'], limits=LIMITS,
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
                            # Dispatch can already be unknown before the finalizer commits.
                            # Wait for its outcome, not merely a state different from intent.
                            outcome = json.loads(row[2]) if row and row[2] else None
                            if row and row[0] != 'intent' and outcome is not None:
                                return row[0], json.loads(row[1]) if row[1] else None, outcome
                            time.sleep(.02)
                        raise AssertionError('Finalization did not finish')
                    def count_intents():
                        with sqlite3.connect(db) as connection:
                            return connection.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
                    def wait_calls(expected):
                        deadline = time.monotonic() + 5
                        while upstream.calls < expected and time.monotonic() < deadline: time.sleep(.02)
                        assert upstream.calls == expected
                    def verify_native(prefix, operation):
                        client_headers = {'x-openai-actor-authorization': 'synthetic-gate', 'x-codex-future-header': 'synthetic-value', 'x-codex-image-turn-id': 'synthetic-turn', 'x-codex-turn-metadata': '{"synthetic":true}',
                            'User-Agent': 'Codex Desktop synthetic-client', 'originator': 'synthetic-desktop', 'version': '1.0',
                            'chatgpt-account-id': 'forged-account', 'x-client-private': 'do-not-forward'}
                        wire = ('{ "model" : "synthetic-image", "prompt":"synthetic", "service_tier":"priority", "n":2, "future":{"x":true}'
                            + (', "images":[{"image_url":"' + URL + '","detail":"preserve"}], "mask":{"image_url":"' + URL + '"}' if operation == 'edits' else '') + ' }').encode()
                        before = upstream.calls
                        status, body, headers = request(wire, prefix + '/images/' + operation, headers=client_headers)
                        assert status == 200 and upstream.calls == before + 1, (status, body[:200])
                        path, received, sent_headers = upstream.requests[-1]
                        assert path == '/backend-api/codex/images/' + operation
                        assert received == wire
                        assert sent_headers['accept'] == 'application/json'
                        for key in ('x-codex-future-header', 'x-codex-image-turn-id', 'x-codex-turn-metadata', 'originator', 'version'):
                            assert sent_headers[key] == client_headers[key]
                        assert sent_headers['user-agent'] == client_headers['User-Agent']
                        assert sent_headers['authorization'] == 'Bearer synthetic-upstream-token-for-images'
                        assert 'chatgpt-account-id' not in sent_headers and 'x-client-private' not in sent_headers
                        assert 'x-openai-actor-authorization' not in sent_headers
                        assert headers['x-codex-imagegen-request-id'] == 'synthetic-image-request'
                        assert headers['x-request-id']
                        assert json.loads(body) == json.loads(native_body('synthetic'))
                        state, usage, outcome = ledger()
                        assert state == 'settled' and outcome['kind'] == 'succeeded'
                        assert outcome['actualServiceTier'] == 'default'
                        with sqlite3.connect(root/'state/core.sqlite') as connection:
                            admission = json.loads(connection.execute('SELECT admission_json FROM attempts ORDER BY rowid DESC LIMIT 1').fetchone()[0])
                        assert admission['serviceTier'] == 'priority' and admission.get('reasoningEffort') is None
                        assert usage['images'] == 1 and usage['imageInputTokens'] == 2 and usage['imageOutputTokens'] == 3
                        assert usage['imageInputTextTokens'] == 1 and usage['imageInputImageTokens'] == 1
                        assert usage['estimatedMicros'] == 13
                        status, _, _ = request({'prompt':'default', 'future':42}, prefix + '/images/' + operation)
                        assert status == 200
                        assert json.loads(upstream.requests[-1][1]) == {'prompt':'default','future':42,'model':'synthetic-image'}
                        status, body, _ = request({'prompt':'synthetic','stream':True,'service_tier':'priority'}, prefix + '/images/' + operation)
                        assert status == 200
                        if operation == 'generations': assert body == native_stream(operation)
                        else:
                            event = next(json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: {'))
                            assert event['type'] == 'image_edit.completed' and event['b64_json'] == PNG and event['usage']['input_tokens'] == 2
                            assert json.loads(upstream.requests[-1][1])['stream'] is False
                        assert ledger()[0] == 'settled' and ledger()[2]['actualServiceTier'] == 'default'

                    def verify_denied():
                        before = upstream.calls; intents = count_intents()
                        for body, name in [({'model':'synthetic-denied'}, 'images'), ({'prompt':'synthetic'}, 'chat')]:
                            status, error, _ = request(body, name=name)
                            assert status == 403 and json.loads(error)['error']['code'] == 'model_not_allowed'
                        assert upstream.calls == before and count_intents() == intents

                    def verify_multipart():
                        multipart = b'--synthetic\r\n'
                        for field, value in [('prompt', b'synthetic edit'), ('n', b'3'), ('stream', b'false'), ('future', b'preserved')]:
                            multipart += f'Content-Disposition: form-data; name="{field}"\r\n\r\n'.encode() + value + b'\r\n--synthetic\r\n'
                        for field in ('image[]', 'mask'):
                            multipart += f'Content-Disposition: form-data; name="{field}"; filename="synthetic.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + base64.b64decode(PNG) + b'\r\n--synthetic' + (b'\r\n' if field == 'image[]' else b'--\r\n')
                        assert request(multipart, '/v1/images/edits', content_type='multipart/form-data; boundary=synthetic')[0] == 200
                        assert json.loads(upstream.requests[-1][1]) == {'model':'synthetic-image','prompt':'synthetic edit','n':3,'stream':False,'future':'preserved', 'images':[{'image_url':URL}], 'mask':{'image_url':URL}}
                        assert request(multipart, '/backend-api/codex/images/edits', content_type='multipart/form-data; boundary=synthetic')[0] == 415

                    def verify_missing_usage():
                        assert request({'prompt':'missing-usage'})[0] == 200
                        state, usage, outcome = ledger()
                        assert state == 'unknown' and usage['completeness'] == 'partial' and 'imageInputTokens' not in usage and 'imageOutputTokens' not in usage
                        assert usage['images'] == 1 and outcome['kind'] == 'succeeded'

                    def verify_incomplete_stream(fault):
                        before, intents = upstream.calls, count_intents()
                        status, _, _ = request({'prompt':fault,'stream':True})
                        assert status == 200 and ledger()[2]['kind'] == 'failed'
                        assert upstream.calls == before + 1 and count_intents() == intents + 1

                    for operation, output_format in (('generations', 'gif'), ('edits', 'gif'), ('generations', 'svg')):
                        before = upstream.calls
                        payload = {'prompt': 'synthetic', 'output_format': output_format}
                        if output_format == 'gif':
                            payload.update(GIF_ANIMATION)
                        if operation == 'edits':
                            payload['images'] = [{'image_url': URL}]
                        status, body, _ = request(payload, '/v1/images/' + operation)
                        assert status == 200 and upstream.calls == before + 1
                        assert json.loads(body)['data'][0]['b64_json'] == OUTPUTS[output_format]
                        path, received, sent_headers = upstream.requests[-1]
                        assert path == '/backend-api/codex/images/' + operation
                        provider_input = json.loads(received)
                        assert all(provider_input.get(field) == value for field, value in payload.items())
                        assert provider_input.get('stream') is not True
                        assert sent_headers['accept'] == 'application/json'
                        assert ledger()[0] == ('unknown' if output_format == 'svg' else 'settled')
                    if args.smoke:
                        verify_native('/v1', 'generations')
                        verify_native('/backend-api/codex', 'edits')
                        verify_denied()
                        verify_missing_usage()
                        verify_incomplete_stream('stream-abort')
                        if transport == 'http':
                            verify_multipart()
                        print('PASS: native Images smoke via ' + transport, flush=True)
                        continue
                    for operation, output_format in (('generations', 'gif'), ('edits', 'gif'), ('generations', 'svg')):
                        before = upstream.calls
                        intents = count_intents()
                        status, body, _ = request(
                            {'prompt':'wrong-native-format', 'output_format':output_format},
                            '/v1/images/' + operation)
                        assert status == 502 and json.loads(body)['error']['code'] == 'invalid_upstream_image_format'
                        assert PNG.encode() not in body and upstream.calls == before + 1
                        state, usage, outcome = ledger()
                        assert count_intents() == intents + 1
                        assert state == ('unknown' if output_format == 'svg' else 'settled')
                        assert usage['imageInputTokens'] == 2 and usage['imageOutputTokens'] == 3
                        assert usage['images'] == 1 and outcome['failure'] == 'invalid_upstream_response'
                    status, body, _ = request({'prompt':'svg-author-usage', 'output_format':'svg'})
                    assert status == 200 and json.loads(body)['svg_usage']['output_tokens'] == 20
                    state, usage, outcome = ledger()
                    assert state == 'settled' and usage['completeness'] == 'complete' and usage['imageOutputTokens'] == 3
                    assert usage['svgInputTokens'] == 10 and usage['svgOutputTokens'] == 20 and usage['priceCompleteness'] == 'partial'
                    assert outcome['kind'] == 'succeeded'
                    before = upstream.calls; intents = count_intents()
                    for invalid in ({'output_format':'svg', 'svg':{'model':'synthetic-author'}},
                                    {'output_format':'gif', 'stream':True},
                                    {'output_format':'svg', 'n':2}):
                        status, body, _ = request(invalid)
                        assert status == 400 and b'not dispatched' in body
                    assert upstream.calls == before and count_intents() == intents
                    for operation in ('generations', 'edits'):
                        for raw in (b'{"model":"synthetic-image","stream":true,"output_format":"png","output_format":"gif"}',
                                    b'{"model":"synthetic-image","output_format":"png","output_format":"svg"}',
                                    b'{"model":"synthetic-image","output_format":"png","output_fo\\u0072mat":"gif"}'):
                            assert request(raw, '/v1/images/' + operation)[0] == 400
                    assert upstream.calls == before and count_intents() == intents
                    for output_format in ('gif', 'svg', 'synthetic-future'):
                        for fault in ('non-json', 'empty', 'extended-mixed', 'extended-sse', 'extended-error', 'json-stream-html'):
                            before = upstream.calls
                            status, body, _ = request({'prompt':fault, 'output_format':output_format})
                            assert status == 502 and upstream.calls == before + 1, (output_format, fault, status)
                            state, usage, outcome = ledger()
                            assert outcome['kind'] == 'failed'
                            if fault in ('empty', 'extended-mixed', 'json-stream-html'):
                                assert usage['imageOutputTokens'] == 3
                    before = upstream.calls; intents = count_intents()
                    status, _, _ = request({'model':'synthetic-host','input':'synthetic',
                        'tools':[{'type':'image_generation', 'output_format':'svg', 'svg':{'model':'synthetic-author'}}]}, '/v1/responses', name='both')
                    assert status == 400 and upstream.calls == before and count_intents() == intents
                    for output_format in ('gif', 'svg'):
                        status, _, _ = request({'output_format':output_format}, name='chat')
                        assert status == 403 and upstream.calls == before and count_intents() == intents
                    # Real GIF/SVG bytes, plus an opaque future format, through both client
                    # JSON/SSE and native WS; tool counters never rewrite the returned usage.
                    for output_format in ('gif', 'svg', 'synthetic-future'):
                        for streaming in (False, True):
                            status, body, _ = request({'model':'synthetic-host','input':'synthetic', 'stream':streaming,
                                'tools':[{'type':'image_generation', 'output_format':output_format}]}, '/v1/responses', name='both')
                            assert status == 200, (output_format, transport, body[:200])
                            result = (next(json.loads(line[6:])['response'] for line in body.splitlines()
                                if line.startswith(b'data: {') and json.loads(line[6:])['type'] == 'response.completed')
                                if streaming else json.loads(body))
                            assert result['output'][0]['result'] == OUTPUTS[output_format]
                            state, usage, outcome = ledger()
                            assert state == ('unknown' if output_format == 'svg' else 'settled'), (transport, output_format, streaming, state, usage, outcome)
                        if transport == 'websocket':
                            with dial(port, token=policies['both']['secret'], timeout=15) as peer:
                                send(peer, {'type':'response.create', 'model':'synthetic-host', 'input':'synthetic',
                                    'tools':[{'type':'image_generation', 'output_format':output_format}]}, masked=True)
                                while True:
                                    _, data = receive(peer); event = json.loads(data)
                                    assert event['type'] != 'error', event
                                    if event['type'] == 'response.completed': break
                                assert event['response']['output'][0]['result'] == OUTPUTS[output_format]
                            assert ledger()[0] == ('unknown' if output_format == 'svg' else 'settled')
                    for prompt in ('svg-root-usage', 'svg-item-usage', 'invalid-usage'):
                        status, body, _ = request({'model':'synthetic-host','input':prompt,
                            'tools':[{'type':'image_generation', 'output_format':'svg'}]}, '/v1/responses', name='both')
                        assert status == 200, (prompt, body[:200])
                        result = json.loads(body)
                        assert result['output'][0]['result'] == OUTPUTS['svg']
                        state, usage, outcome = ledger()
                        assert state == ('unknown' if prompt == 'invalid-usage' else 'settled') and outcome['kind'] == 'succeeded'
                        assert usage['inputTokens'] == 5 and usage['outputTokens'] == 7 and usage['imageInputTokens'] == 2
                        if prompt == 'invalid-usage':
                            assert usage.get('imageOutputTokens') is None and usage['estimatedMicros'] == 16
                        else:
                            assert usage['imageOutputTokens'] == 3 and usage['estimatedMicros'] == 25
                            assert (result if prompt == 'svg-root-usage' else result['output'][0])['svg_usage']['output_tokens'] == 20
                    status, body, _ = request({'model':'synthetic-host','input':'invalid-host-usage',
                        'tools':[{'type':'image_generation'}]}, '/v1/responses', name='both')
                    assert status == 200 and 'input_tokens' not in json.loads(body)['usage']
                    assert json.loads(body)['usage']['synthetic_future'] == {'nullable':None, 'large':9007199254740993}
                    assert ledger()[0] == 'unknown'
                    status, body, _ = request({'model':'synthetic-host','input':'mixed-invalid-usage',
                        'tools':[{'type':'image_generation'}]}, '/v1/responses', name='both')
                    assert status == 200 and len(json.loads(body)['output']) == 2
                    state, usage, outcome = ledger()
                    assert state == 'unknown' and outcome['kind'] == 'succeeded'
                    assert usage['imageInputTokens'] == 6 and usage['imageOutputTokens'] == 3
                    before = upstream.calls
                    status, _, _ = request({'model':'synthetic-host','input':'invalid-output',
                        'tools':[{'type':'image_generation'}]}, '/v1/responses', name='both')
                    assert status == 502 and upstream.calls == before + 1 and ledger()[2]['kind'] == 'failed'
                    for operation in ('generations', 'edits'):
                        status, body, _ = request({'output_format':'synthetic-future', 'stream':True}, '/v1/images/' + operation)
                        assert status == 200
                        completions = [json.loads(line[6:]) for line in body.splitlines()
                            if line.startswith(b'data: {') and json.loads(line[6:])['type'].endswith('.completed')]
                        assert completions[-1]['b64_json'] == OUTPUTS['synthetic-future']
                        assert json.loads(upstream.requests[-1][1])['stream'] is True
                        assert upstream.requests[-1][2]['accept'] == 'text/event-stream'
                        assert ledger()[0] == 'settled'
                    # Unknown native formats preserve the requested non-stream mode.
                    status, body, _ = request({'output_format':'synthetic-future'})
                    assert status == 200 and json.loads(body)['data'][0]['b64_json'] == OUTPUTS['synthetic-future']
                    assert json.loads(upstream.requests[-1][1]).get('stream') is not True
                    assert ledger()[0] == 'settled'
                    for prefix in ('/v1', '/backend-api/codex'):
                        for operation in ('generations', 'edits'):
                            verify_native(prefix, operation)
                    for operation in ('edits', 'generations'):
                        for fault in ('json-stream', 'json-stream-multiple', 'json-stream-empty', 'json-stream-invalid', 'json-stream-mixed', 'json-stream-html'):
                            before = upstream.calls
                            status, body, headers = request({'prompt':fault, 'stream':True}, '/v1/images/' + operation)
                            assert upstream.calls == before + 1
                            if fault in ('json-stream', 'json-stream-multiple'):
                                assert status == 200 and headers['content-type'] == 'text/event-stream', (status, body[:200])
                                events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: {')]
                                assert len(events) == (2 if fault.endswith('multiple') else 1)
                                assert all(e['type'] == ('image_edit' if operation == 'edits' else 'image_generation') + '.completed' and e['b64_json'] == PNG and e['created_at'] == 1 for e in events)
                                assert sum('usage' in e for e in events) == 1 and body.endswith(b'data: [DONE]\n\n')
                                state, usage, outcome = ledger()
                                assert state == 'settled' and usage['images'] == len(events) and usage['estimatedMicros'] == 13
                            else:
                                assert status == 502 and json.loads(body)['error']['code'] == ('invalid_upstream_content_type' if fault.endswith('html') else 'invalid_upstream_image'), (status, body[:200])
                                state, usage, outcome = ledger()
                                assert outcome['kind'] == 'failed'
                                if fault in ('json-stream-mixed', 'json-stream-empty'):
                                    assert state == 'settled' and usage['imageInputTokens'] == 2 and usage['imageOutputTokens'] == 3
                                    assert usage['images'] == (1 if fault.endswith('mixed') else 0)
                                else: assert state == 'unknown'
                    for operation in ('edits', 'generations'):
                        for completion_status in ('in_progress', 'queued', 'failed', 'cancelled', 'incomplete'):
                            for partial in (False, True):
                                prompt = 'json-stream-status-' + completion_status + ('-partial' if partial else '')
                                status, body, _ = request({'prompt':prompt, 'stream':True}, '/v1/images/' + operation)
                                assert status == 502 and b'.completed' not in body, (completion_status, status, body[:200])
                                state, usage, outcome = ledger()
                                complete = not partial and completion_status in ('failed', 'cancelled')
                                assert state == ('settled' if complete else 'unknown') and outcome['kind'] == 'failed'
                                assert usage['imageInputTokens'] == 2
                                if partial: assert 'imageOutputTokens' not in usage
                                else: assert usage['imageOutputTokens'] == 3
                                assert usage['completeness'] == ('complete' if complete else 'partial')
                    for author_prompt in ('author-stream-missing', 'author-stream-decrease'):
                        status, body, _ = request({'prompt':author_prompt, 'stream':True, 'n':2})
                        assert status == 200 and body.count(b'image_generation.completed') == 2
                        state, usage, outcome = ledger()
                        assert state == 'settled' and outcome['kind'] == 'succeeded', (state, usage, outcome)
                        assert usage['svgInputTokens'] == 10 and usage['svgOutputTokens'] == 20
                        assert usage['images'] == 2 and usage['priceCompleteness'] == 'partial'
                    # SSE completions are images in arrival order; usage is request-level cumulative.
                    for streaming in (False, True):
                        for fault in ('stream-multiple', 'stream-multiple-repeated', 'stream-multiple-late'):
                            before = upstream.calls
                            status, body, _ = request({'prompt':fault, 'stream':streaming, 'n':2})
                            assert status == 200 and upstream.calls == before + 1, (fault,status,body[:200])
                            if streaming:
                                events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: {')]
                                images = [e['b64_json'] for e in events if e['type'].endswith('.completed')]
                            else: images = [e['b64_json'] for e in json.loads(body)['data']]
                            assert images == [PNG, PNG if fault.endswith('repeated') else base64.b64encode(b'synthetic-second-image').decode()], images
                            state, usage, outcome = ledger()
                            assert state == 'settled' and outcome['kind'] == 'succeeded' and usage['images'] == 2
                            assert usage['imageInputTokens'] == (2 if fault.endswith('repeated') else 4)
                            assert usage['imageOutputTokens'] == (3 if fault.endswith('repeated') else 7)
                            assert usage['estimatedMicros'] == (13 if fault.endswith('repeated') else 29)
                    for fault in ('stream-multiple-malformed', 'stream-multiple-duplicate-index'):
                        status, body, _ = request({'prompt':fault, 'n':2})
                        assert status == 502, (fault,status,body[:200])
                        state, usage, outcome = ledger()
                        assert state == 'settled' and outcome['kind'] == 'failed' and usage['images'] == 1
                        assert usage['imageInputTokens'] == 4 and usage['imageOutputTokens'] == 7
                    for fault in ('stream-mixed', 'stream-status-in_progress', 'stream-status-failed'):
                        status, body, _ = request({'prompt':fault})
                        assert status == 502, (fault,status,body[:200])
                        state, usage, outcome = ledger()
                        assert outcome['kind'] == 'failed' and usage['imageInputTokens'] == 2 and usage['imageOutputTokens'] == 3
                        assert state == ('unknown' if fault.endswith('in_progress') else 'settled')
                    for prompt, expected in (('stream-error',400), ('stream-error-explicit',422)):
                        status, body, _ = request({'prompt':prompt})
                        assert status == expected, (prompt,status,body[:200])
                        if prompt == 'stream-error':
                            # The same provider rejection via JSON has the same HTTP status/error.
                            json_status, json_body, _ = request({'prompt':prompt}, '/v1/images/edits')
                            assert status == json_status and json.loads(body)['error']['code'] == json.loads(json_body)['error']['code']
                    verify_denied()
                    verify_multipart()
                    for fault, expected in [('http400',400), ('http429',429), ('http500',502)]:
                        before = upstream.calls
                        status, error, headers = request({'prompt':fault})
                        assert status == expected and upstream.calls == before + 1, (status,error[:200])
                        assert json.loads(error)['error']['code'] == 'synthetic_provider_error'
                        assert 'acct-private' not in error.decode() and headers['x-request-id']
                        assert headers['x-codex-imagegen-request-id'] == 'synthetic-image-request'
                        if expected == 429: assert headers['retry-after'] == '1'
                        assert ledger()[0] == ('unknown' if expected == 502 else 'settled')
                    for fault in ('empty', 'non-json', 'oversize'):
                        status, body, _ = request({'prompt':fault}, '/v1/images/edits')
                        assert status == (502 if fault == 'oversize' else 200), (fault,status,body[:100])
                        state, usage, outcome = ledger()
                        assert outcome['kind'] == 'failed'
                        if fault != 'empty': assert state == 'unknown'
                    verify_missing_usage()
                    for prefix in ('/v1', '/backend-api/codex'):
                        for operation in ('generations', 'edits'):
                            before = upstream.calls
                            status, body, headers = request({'prompt':'stream-error','stream':True}, prefix + '/images/' + operation)
                            assert upstream.calls == before + 1
                            assert status == (400 if operation == 'edits' else 200)
                            assert b'acct-split-secret' not in body and b'user-synthetic@example.invalid' not in body
                            assert b'synthetic-private-member' not in body
                            events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith(b'data: {')]
                            if operation == 'generations':
                                assert b'event: error\n' in body and b'response.failed' not in body
                                assert b'data: [DONE]' not in body
                                assert [event['type'] for event in events] == ['image_generation.partial_image', 'error']
                                failure = events[-1]
                            else:
                                failure = json.loads(body)
                            error = failure['error']
                            assert error['code'] == 'synthetic_provider_error' and error['type'] == 'invalid_request_error'
                            assert error['param'] == 'prompt' and '[redacted]' in error['message']
                            assert error['request_id'] == headers['x-request-id']
                            assert ledger()[2]['kind'] == 'failed'
                    for fault in ('stream-abort', 'stream-empty'):
                        verify_incomplete_stream(fault)
                    # Non-stream generation buffers until validated EOF, including failures after usage.
                    for fault in ('stream-abort', 'stream-empty', 'stream-duplicate', 'stream-tail', 'stream-missing-created', 'stream-error'):
                        before = upstream.calls
                        status, body, headers = request({'prompt':fault})
                        assert status == (400 if fault == 'stream-error' else 502) and headers['content-type'].startswith('application/json'), (fault,status,body[:200])
                        assert 'error' in json.loads(body) and upstream.calls == before + 1
                        state, usage, outcome = ledger()
                        assert outcome['kind'] == 'failed'
                        if fault in ('stream-tail', 'stream-duplicate', 'stream-missing-created'):
                            assert usage['images'] == 1 and usage['imageOutputTokens'] == 3
                        if fault != 'stream-error': assert state == 'unknown' or usage is not None
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
                    # Reserve two 32 MiB bodies to fill the 64 MiB budget before upload. HTTP
                    # and WS readers share this budget, and rejection must precede intent/dispatch.
                    reservation_header = ('POST /v1/images/generations HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer '
                        + policies['images']['secret'] + '\r\nContent-Type: application/json\r\nContent-Length: 33554432\r\n\r\n').encode()
                    large_native = {'model':'synthetic-image', 'prompt':'synthetic', 'future':'x' * (20 * 1024 * 1024)}
                    before = upstream.calls; intents = count_intents()
                    holders = [socket.create_connection(('127.0.0.1', port), timeout=3) for _ in range(2)]
                    try:
                        for held in holders: held.sendall(reservation_header + b'{"model":')
                        time.sleep(.2)
                        with socket.create_connection(('127.0.0.1', port), timeout=10) as exhausted:
                            exhausted.sendall(reservation_header)
                            started = time.monotonic()
                            response = http.client.HTTPResponse(exhausted); response.begin()
                            assert time.monotonic() - started >= 4.8
                            assert response.status == 503 and response.getheader('Retry-After') == '1'
                            assert json.loads(response.read())['error']['code'] == 'capacity_exhausted'
                        assert upstream.calls == before and count_intents() == intents
                        with socket.create_connection(('127.0.0.1', port), timeout=10) as chunked:
                            chunked.sendall(('POST /backend-api/codex/images/generations HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer '
                                + policies['images']['secret'] + '\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n').encode())
                            # Stop immediately after crossing the unreserved threshold, then read
                            # the early rejection instead of uploading more into a closed socket.
                            chunked.sendall(b'800000\r\n' + b' ' * (8 * 1024 * 1024) + b'\r\n1\r\nx\r\n')
                            response = http.client.HTTPResponse(chunked); response.begin()
                            assert response.status == 503 and response.getheader('Retry-After') == '1'
                            assert json.loads(response.read())['error']['code'] == 'capacity_exhausted'
                        assert upstream.calls == before and count_intents() == intents
                        if transport == 'websocket':
                            for held in holders: held.sendall(b' ')
                            with dial(port, token=policies['both']['secret'], timeout=15) as sock:
                                send(sock, b' ' * (17 * 1024 * 1024), masked=True, maximum_bytes=18 * 1024 * 1024)
                                opcode, data = receive(sock)
                                error = json.loads(data)
                                assert opcode == 1 and error['type'] == 'error' and error['status'] == 503
                                assert error['error']['code'] == 'capacity_exhausted'
                                assert upstream.calls == before and count_intents() == intents
                                # A budget rejection ends only the message; the WS connection stays usable.
                                send(sock, {'type':'response.create','model':'synthetic-host','input':'synthetic'}, masked=True)
                                while True:
                                    _, data = receive(sock)
                                    event = json.loads(data)
                                    assert event['type'] != 'error', event
                                    if event['type'] == 'response.completed': break
                                ledger()
                    finally:
                        for held in holders: held.close()
                    # Partial upload disconnect releases the full Content-Length reservation.
                    time.sleep(.2)
                    before = upstream.calls; intents = count_intents()
                    assert request(large_native)[0] == 200
                    assert ledger()[0] == 'settled'
                    assert upstream.calls == before + 1 and count_intents() == intents + 1
                    # A queued HTTP upload proceeds once the incomplete holder disconnects.
                    holders = [socket.create_connection(('127.0.0.1', port), timeout=10) for _ in range(2)]
                    for held in holders: held.sendall(reservation_header + b'{')
                    time.sleep(.15)
                    for _ in range(4):
                        abandoned = socket.create_connection(('127.0.0.1', port), timeout=10)
                        abandoned.sendall(reservation_header)
                        time.sleep(.05)
                        abandoned.close()
                    time.sleep(.2)
                    with ThreadPoolExecutor(max_workers=1) as queued:
                        waiting = queued.submit(request, large_native)
                        time.sleep(.25)
                        assert not waiting.done()
                        for held in holders: held.close()
                        assert waiting.result(timeout=15)[0] == 200
                    assert ledger()[0] == 'settled'
                    before = upstream.calls; intents = count_intents()
                    with socket.create_connection(('127.0.0.1', port), timeout=12) as stalled:
                        stalled.sendall(reservation_header + b'{"model":')
                        started = time.monotonic()
                        response = http.client.HTTPResponse(stalled); response.begin()
                        stalled_error = json.loads(response.read())['error']['code']
                        assert response.status == 408 and stalled_error == 'request_body_timeout', (response.status, stalled_error)
                        assert time.monotonic() - started >= 9
                    assert upstream.calls == before and count_intents() == intents
                    assert request(large_native, '/backend-api/codex/images/generations')[0] == 200
                    assert ledger()[0] == 'settled'
                    assert upstream.calls == before + 1 and count_intents() == intents + 1
                    # Responses managed tool evidence remains independent from native Images accounting.
                    status, body, _ = request({'model':'synthetic-host','input':'synthetic','tools':[{'type':'image_generation'}]}, '/v1/responses', name='both')
                    assert status == 200, (status,body[:200])
                    state, usage, _ = ledger()
                    assert state == 'settled' and usage['inputTokens'] == 5 and usage['imageInputTokens'] == 2 and usage['estimatedMicros'] == 25
                    if args.browser and transport == 'http':
                        result = subprocess.run(['node', str(repository / 'web/scripts/live-images.mjs'), str(ports['admin']), str(port), str(repository / 'artifacts/image-management-ui')], input=json.dumps({'credential': ADMIN}).encode(), capture_output=True, timeout=60)
                        assert result.returncode == 0, 'Image browser validation failed; private output withheld'
                    # Reuse the same synthetic Keys after restart with a short deadline.
                    stop(process)
                    value = json.loads(config.read_text())
                    value.update(executionTimeoutSeconds=5, firstResponseTimeoutSeconds=1, progressTimeoutSeconds=1)
                    config.write_text(json.dumps(value))
                    process, ports = start(str(args.binary.resolve()), config, root, admin_token_file=admin)
                    port = ports['data']
                    before = upstream.calls
                    for prompt, expected, code in (
                        ('json-slow', 200, None), ('json-stalled', 504, 'execution_progress_timeout'),
                        ('json-truncated', 502, 'execution_indeterminate'),
                    ):
                        before = upstream.calls; intents = count_intents()
                        wire = json.dumps({'model':'synthetic-image','prompt':prompt,'stream':False}).encode()
                        status, body, _ = request(wire)
                        assert status == expected, (prompt,status,body[:200])
                        assert upstream.calls == before + 1 and count_intents() == intents + 1
                        _, received, sent_headers = upstream.requests[-1]
                        assert received == wire and sent_headers['accept'] == 'application/json'
                        state, usage, outcome = ledger()
                        if code is None:
                            assert body == native_body(prompt)
                            assert state == 'settled' and usage['completeness'] == 'complete' and outcome['kind'] == 'succeeded'
                        else:
                            assert json.loads(body)['error']['code'] == code
                            assert state == 'unknown' and usage is None and outcome['kind'] == 'failed'
                    before = upstream.calls
                    started = time.monotonic()
                    status, body, _ = request({'prompt':'unknown-native-events'})
                    assert status == 504 and json.loads(body)['error']['code'] == 'execution_first_response_timeout', (status,body[:200])
                    assert time.monotonic() - started < 2
                    assert upstream.calls == before + 1 and ledger()[0] == 'unknown'
                    print('PASS: native Images byte/header/path parity, multipart, usage, SSE, provider failures, unknown/no replay and capacity via ' + transport)
                finally:
                    upstream.release.set()
                    stop(process)
    finally:
        upstream.release.set()
        upstream.shutdown(); upstream.server_close(); worker.join(timeout=3)

if __name__ == '__main__': main()
