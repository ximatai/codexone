#!/usr/bin/env python3
"""Remote compaction v2 over real HTTP/SSE/WS sockets and the persistent execution kernel."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from verify_protocol import TOKEN, connect, latest, start, stop
from verify_websocket import dial, receive, send, turn


class Provider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_args):
        pass

    def events(self, document):
        assert document['model'] == 'synthetic-text'
        with self.server.guard:
            self.server.calls += 1
            index = self.server.calls
        assert index <= 64
        serialized = json.dumps(document['input'])
        compact = any(item.get('type') == 'compaction_trigger' for item in document['input']) if isinstance(document['input'], list) else False
        if isinstance(document['input'], list):
            assert all('id' not in item for item in document['input'] if item.get('type') in ('reasoning', 'compaction') and item.get('encrypted_content'))
        item = ({'type': 'compaction', 'encrypted_content': f'synthetic-v2-cipher-{index}'} if compact or 'unsolicited' in serialized else
                {'type': 'message', 'id': f'msg_v2_{index}', 'role': 'assistant', 'status': 'completed',
                 'content': [{'type': 'output_text', 'text': 'synthetic compact continuation', 'annotations': []}]})
        response = {'id': f'resp_v2_{index}', 'object': 'response', 'model': 'synthetic-text', 'status': 'completed',
                    'output': [item], 'usage': {'input_tokens': 5, 'output_tokens': 3, 'total_tokens': 8,
                    'input_tokens_details': {'cached_tokens': 0}}}
        events = [{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': [], 'usage': None}}]
        if compact:
            assert document['input'][-1] == {'type': 'compaction_trigger'}
            events.append({'type': 'response.output_item.added', 'output_index': 0,
                           'item': {'type': 'compaction', 'encrypted_content': ''}})
        if 'early-tool' in serialized:
            return events + [{'type': 'response.output_item.done', 'output_index': 1, 'item': {
                'type': 'function_call', 'id': 'fc_v2_forbidden', 'call_id': 'call_v2_forbidden',
                'name': 'local_tool', 'arguments': '{}'}}]
        if 'missing-done' not in serialized and 'partial-eof' not in serialized:
            events.append({'type': 'response.output_item.done', 'output_index': 0, 'item': item})
        if 'duplicate-window' in serialized:
            response['output'] = [item, {**item, 'encrypted_content': 'synthetic-v2-extra'}]
        if 'mismatched-window' in serialized:
            response['output'] = [{**item, 'encrypted_content': 'synthetic-v2-changed'}]
        if 'missing-window' in serialized:
            response['output'] = []
        if 'new-tool' in serialized:
            response['output'] = [{'type': 'function_call', 'id': 'fc_v2_forbidden', 'call_id': 'call_v2_forbidden',
                                   'name': 'local_tool', 'arguments': '{}'}]
        if 'partial-eof' not in serialized:
            events.append({'type': 'response.completed', 'response': response})
        return events

    def do_POST(self):
        assert self.path == '/v1/responses' and self.headers.get('Authorization') is None
        size = int(self.headers['Content-Length'])
        assert 0 < size <= 524288
        document = json.loads(self.rfile.read(size))
        events = self.events(document)
        if document.get('stream'):
            body = ''.join('data: ' + json.dumps(event) + '\n\n' for event in events).encode()
            content_type = 'text/event-stream'
        else:
            body = json.dumps(events[-1]['response']).encode()
            content_type = 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        assert self.path == '/v1/responses' and self.headers.get('Authorization') is None
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.close_connection = True
        self.connection.settimeout(5)
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                if opcode == 9:
                    send(self.connection, data, opcode=10)
                    continue
                assert opcode == 1
                document = json.loads(data)
                for event in self.events(document):
                    send(self.connection, event)
                if any(fault in json.dumps(document) for fault in ('partial-eof', 'early-tool')):
                    return
        except (EOFError, ConnectionError, TimeoutError):
            pass


def request(prompt='compact', streaming=True):
    return {'model': 'synthetic-text', 'stream': streaming,
            'input': [{'role': 'user', 'content': prompt}, {'type': 'compaction_trigger'}]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.calls = 0
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    try:
        for transport in ('http', 'websocket'):
            with tempfile.TemporaryDirectory(prefix='codexone-compact-v2-') as temporary:
                root = Path(temporary)
                config = root / 'identity.json'
                profile = {'principal': 'p', 'keyID': 'k', 'namespace': 'synthetic', 'identity': 'i',
                           'keySHA256': hashlib.sha256(TOKEN.encode()).hexdigest(), 'reservedMicros': 10,
                           'models': [{'id': 'synthetic-text', 'inputMicrosPerMillion': 1000000, 'outputMicrosPerMillion': 1000000}],
                           'upstreamBaseURL': f'http://127.0.0.1:{provider.server_port}/v1', 'upstreamTransport': transport}
                config.write_text(json.dumps(profile))
                config.chmod(0o600)
                process, ports = start(str(args.binary.resolve()), config, root)
                db_path = root / 'state/core.sqlite'
                try:
                    for prefix in ('/v1', '/backend-api/codex'):
                        status, body = connect(ports['data'], 'POST', prefix + '/responses', request(streaming=False))
                        assert status == 200, (status, body)
                        output = json.loads(body)['output']
                        assert output[0]['type'] == 'compaction' and 'id' not in output[0]
                        assert latest(db_path, 'settled')['inputTokens'] == 5
                        followup = {'model': 'synthetic-text', 'input': [{**output[0], 'id': 'client-local-compaction'}] + [{'role': 'user', 'content': 'continue'}]}
                        assert connect(ports['data'], 'POST', prefix + '/responses', followup)[0] == 200
                    status, body = connect(ports['data'], 'POST', '/v1/responses', request())
                    assert status == 200 and b'response.completed' in body and b'[DONE]' in body
                    latest(db_path, 'settled')
                    for fault in ('duplicate-window', 'mismatched-window', 'missing-window', 'missing-done', 'new-tool'):
                        value = request(fault)
                        value['tools'] = [{'type': 'function', 'name': 'local_tool'}]
                        status, body = connect(ports['data'], 'POST', '/v1/responses', value)
                        assert status == 200 and b'"type":"error"' in body and b'[DONE]' not in body, (fault, status, body)
                        assert latest(db_path, 'settled')['inputTokens'] == 5
                    status, body = connect(ports['data'], 'POST', '/v1/responses', request('partial-eof'))
                    assert status == 200 and b'execution_indeterminate' in body and b'[DONE]' not in body
                    assert latest(db_path, 'unknown') is None
                    value = request('early-tool')
                    value['tools'] = [{'type': 'function', 'name': 'local_tool'}]
                    status, body = connect(ports['data'], 'POST', '/v1/responses', value)
                    assert status == 200 and b'"type":"error"' in body and b'call_v2_forbidden' not in body
                    assert latest(db_path, 'unknown') is None
                    status, body = connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'unsolicited'})
                    assert status == 502 and b'synthetic-v2-cipher' not in body
                    count = provider.calls
                    for items in ([{'type': 'compaction_trigger', 'id': 'forged'}],
                                  [{'type': 'compaction_trigger'}, {'type': 'compaction_trigger'}],
                                  [{'type': 'compaction_trigger'}, {'role': 'user', 'content': 'tail'}]):
                        assert connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': items})[0] == 400
                    assert connect(ports['data'], 'POST', '/v1/responses/compact', request(streaming=False))[0] == 400
                    assert provider.calls == count
                    if transport == 'websocket':
                        with dial(ports['data']) as downstream:
                            count = provider.calls
                            with sqlite3.connect(db_path) as db:
                                attempts = db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
                            value = request()
                            value['generate'] = False
                            send(downstream, {'type': 'response.create', **value}, masked=True)
                            try:
                                opcode, data = receive(downstream)
                                assert opcode == 8 or (opcode == 1 and json.loads(data)['type'] == 'error')
                            except (EOFError, ConnectionResetError):
                                pass
                            assert provider.calls == count
                            with sqlite3.connect(db_path) as db:
                                assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == attempts
                    forged = {'model': 'synthetic-text', 'input': [{'type': 'compaction', 'encrypted_content': 'synthetic-v2-forged'}]}
                    assert connect(ports['data'], 'POST', '/v1/responses', forged)[0] == 400 and provider.calls == count
                    if transport == 'websocket':
                        with dial(ports['data'], extension_offer=True) as downstream:
                            events = turn(downstream, request())
                            assert events[-1]['type'] == 'response.completed'
                            output = events[-1]['response']['output']
                            events = turn(downstream, {'model': 'synthetic-text', 'input': output + [{'role': 'user', 'content': 'continue'}],
                                                      'previous_response_id': events[-1]['response']['id']})
                            assert events[-1]['type'] == 'response.completed'
                        latest(db_path, 'settled')
                    else:
                        with sqlite3.connect(db_path) as db:
                            db.execute("CREATE TRIGGER fail_v2_binding BEFORE INSERT ON bindings BEGIN SELECT RAISE(ABORT,'synthetic fault'); END")
                        status, body = connect(ports['data'], 'POST', '/v1/responses', request('binding-fault', streaming=False))
                        assert status == 503 and b'synthetic-v2-cipher' not in body
                        assert latest(db_path, 'settled')['inputTokens'] == 5
                    with sqlite3.connect(db_path) as db:
                        modes = [json.loads(row[0]).get('mode') for row in db.execute('SELECT admission_json FROM attempts')]
                        assert 'compact' in modes and set(modes) <= {'compact', 'generation'}
                    print(f'PASS: {transport} compaction v2 uses normal Responses; idless context binds; JSON/SSE, failures preserve usage; invalid controls do not dispatch')
                finally:
                    stop(process)
                if transport == 'websocket':
                    for changed in ({'principal': 'other'}, {'identity': 'other'}):
                        config.write_text(json.dumps({**profile, **changed}))
                        process, ports = start(str(args.binary.resolve()), config, root)
                        try:
                            count = provider.calls
                            assert connect(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': output})[0] == 400
                            assert provider.calls == count
                        finally:
                            stop(process)
                for file in (root / 'state').glob('core.sqlite*'):
                    assert b'synthetic-v2-cipher' not in file.read_bytes()
        print('PASS: cross-principal/changed-identity v2 context is rejected before dispatch; core storage contains fingerprints, not opaque payloads')
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=3)


if __name__ == '__main__':
    main()
