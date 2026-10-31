#!/usr/bin/env python3
"""Synthetic native WS controls, late acknowledgements and unexpected generation ledger."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_websocket import dial, send, receive, turn

PRIVATE = 'synthetic-payload-must-not-enter-logs'


def event(sock):
    opcode, data = receive(sock)
    assert opcode == 1, (opcode, data)
    return json.loads(data)


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        assert self.headers['x-codex-future-header'] == 'synthetic-value'
        assert self.headers.get('x-openai-actor-authorization') is None
        assert self.headers.get('chatgpt-account-id') is None
        key = self.headers['Sec-WebSocket-Key']
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode())
        self.end_headers()
        pending = {}
        recent = None
        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                value = json.loads(data)
                kind = value['type']
                if kind == 'response.interrupt':
                    response, lane, prompt = pending.pop(value['response_id'])
                    with self.server.guard:
                        self.server.interrupts += 1
                    ack = dict(type='response.interrupt.accepted', response_id=response['id'])
                    done = dict(type='response.completed', response=response, **lane)
                    for item in ([done, ack] if prompt == 'cancel-after' else [ack, done]):
                        send(self.connection, item)
                    recent = response['id']
                elif kind != 'response.create':
                    with self.server.guard:
                        self.server.controls += 1
                        self.server.control_bytes.append(data)
                    if kind == 'synthetic.spawn':
                        send(self.connection, dict(type='response.created', response=dict(id='synthetic-unadmitted', status='in_progress', output=[])))
                    else:
                        send(self.connection, dict(type='synthetic.echo', response_id=recent, payload=value.get('payload')))
                else:
                    with self.server.guard:
                        self.server.creates += 1
                        index = self.server.creates
                    response = dict(id=f'synthetic-response-{index}', status='completed', output=[],
                        usage=dict(input_tokens=5, output_tokens=3, input_tokens_details=dict(cached_tokens=0)))
                    lane = dict(stream_id=value['stream_id']) if 'stream_id' in value else {}
                    send(self.connection, dict(type='response.created', response={**response, 'status': 'in_progress', 'usage': None}, **lane))
                    if value['input'] in ('cancel-before', 'cancel-after', 'drain'):
                        pending[response['id']] = response, lane, value['input']
                    else:
                        send(self.connection, dict(type='response.completed', response=response, **lane))
                        recent = response['id']
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            self.close_connection = True


def counts(db):
    with sqlite3.connect(db) as connection:
        return connection.execute('SELECT state,usage_json,admission_json FROM attempts ORDER BY rowid').fetchall()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.creates = provider.controls = provider.interrupts = 0
    provider.control_bytes = []
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-client-protocol-') as temporary:
            root = Path(temporary)
            config = root/'identity.json'
            config.write_text(json.dumps(dict(principal='synthetic-principal', keyID='synthetic-key',
                keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-provider', identity='synthetic-account',
                reservedMicros=10, executionTimeoutSeconds=10,
                models=[dict(id='synthetic-text', inputMicrosPerMillion=1000000, outputMicrosPerMillion=1000000)],
                upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1', upstreamTransport='websocket')))
            config.chmod(0o600)
            process, ports = start(binary, config, root)
            db = root/'state/core.sqlite'
            try:
                headers = {'x-codex-future-header': 'synthetic-value', 'x-openai-actor-authorization': 'synthetic-gate', 'chatgpt-account-id': 'synthetic-forged'}
                with dial(ports['data'], headers=headers) as sock:
                    send(sock, dict(type='synthetic.unbound', payload=PRIVATE), masked=True)
                    assert event(sock)['status'] == 400
                    assert provider.creates == 0 and provider.controls == 0
                    assert turn(sock, dict(model='synthetic-text', input='first'))[-1]['type'] == 'response.completed'
                    for member in ('input', 'model', 'tools'):
                        send(sock, {'type': 'synthetic.generation', member: None, 'payload': PRIVATE}, masked=True)
                        assert event(sock)['status'] == 400
                    assert provider.controls == 0
                    wire = ('{  \"type\": \"synthetic.future\", \"payload\": ' + json.dumps(PRIVATE) + ' }').encode()
                    send(sock, wire, masked=True)
                    assert event(sock) == dict(type='synthetic.echo', response_id='synthetic-response-1', payload=PRIVATE)
                    assert provider.control_bytes[0] == wire
                    # Controls bypass lane FIFO and route by response ID, including absent stream_id.
                    for prompt in ('cancel-before', 'cancel-after', 'drain'):
                        send(sock, dict(type='response.create', model='synthetic-text', input=prompt, stream_id=prompt), masked=True)
                        created = event(sock)
                        rid = created['response']['id']
                        send(sock, dict(type='response.interrupt', response_id=rid, mode='discard_partial_items'), masked=True)
                        replies = [event(sock), event(sock)]
                        expected = ['response.completed', 'response.interrupt.accepted'] if prompt == 'cancel-after' else ['response.interrupt.accepted', 'response.completed']
                        assert [item['type'] for item in replies] == expected, replies
                        assert all(item['stream_id'] == prompt for item in replies)
                        send(sock, dict(type='response.interrupt', response_id=rid, stream_id=prompt), masked=True)
                        assert event(sock) == dict(type='response.interrupt.failed', response_id=rid, stream_id=prompt)
                    send(sock, dict(type='response.interrupt', response_id='synthetic-foreign', stream_id='other'), masked=True)
                    assert event(sock)['type'] == 'response.interrupt.failed'
                    assert provider.interrupts == 3
                    # Parallel active lanes must never target one another.
                    ids = {}
                    for lane in ('lane_a', 'lane_b'):
                        send(sock, dict(type='response.create', model='synthetic-text', input='drain', stream_id=lane), masked=True)
                        ids[lane] = event(sock)['response']['id']
                    for lane, rid in ids.items():
                        send(sock, dict(type='response.interrupt', response_id=rid), masked=True)
                        replies = [event(sock), event(sock)]
                        assert all(item['stream_id'] == lane for item in replies)
                    assert provider.interrupts == 5
                    assert turn(sock, dict(model='synthetic-text', input='next'))[-1]['type'] == 'response.completed'
                    for _ in range(30):
                        send(sock, dict(type='synthetic.burst', payload=PRIVATE), masked=True)
                    results = [event(sock) for _ in range(30)]
                    assert any(e['type'] == 'error' and e['status'] == 400 for e in results)
                    assert any(e['type'] == 'synthetic.echo' for e in results)
                    assert provider.controls == 1 + sum(e['type'] == 'synthetic.echo' for e in results)
                    assert turn(sock, dict(model='synthetic-text', input='post-rate'))[-1]['type'] == 'response.completed'
                deadline = time.monotonic() + 5
                while any(row[0] == 'intent' for row in counts(db)):
                    assert time.monotonic() < deadline
                    time.sleep(.02)
                assert len(counts(db)) == provider.creates == 8
                assert all(state == 'settled' and json.loads(usage)['estimatedMicros'] == 8 for state, usage, _ in counts(db))
                before = provider.creates
                with dial(ports['data'], headers=headers) as sock:
                    assert turn(sock, dict(model='synthetic-text', input='before-spawn'))[-1]['type'] == 'response.completed'
                    send(sock, dict(type='synthetic.spawn', payload=PRIVATE), masked=True)
                    try:
                        for _ in range(4):
                            opcode, body = receive(sock)
                            if opcode == 8:
                                break
                            assert opcode == 1 and json.loads(body)['type'] == 'error'
                        else:
                            raise AssertionError('No close after unadmitted generation')
                    except (EOFError, ConnectionResetError):
                        pass
                deadline = time.monotonic() + 5
                while len(counts(db)) != 10 or any(row[0] == 'intent' for row in counts(db)):
                    assert time.monotonic() < deadline, counts(db)
                    time.sleep(.02)
                rows = counts(db)
                assert rows[-1][0] == 'unknown' and rows[-1][1] is None
                unexpected = json.loads(rows[-1][2])
                assert unexpected['owner'] == json.loads(rows[-2][2])['owner']
                assert unexpected.get('model') is None
                assert provider.creates == before + 1, 'Unexpected replay'
                with dial(ports['data'], headers=headers) as sock:
                    send(sock, dict(type='response.create', model='synthetic-text', input='drain'), masked=True)
                    assert event(sock)['type'] == 'response.created'
                    send(sock, dict(type='synthetic.spawn'), masked=True)
                    try:
                        for _ in range(4):
                            opcode, body = receive(sock)
                            if opcode == 8:
                                break
                            assert opcode == 1 and json.loads(body)['type'] == 'error'
                        else:
                            raise AssertionError('No close after unadmitted generation')
                    except (EOFError, ConnectionResetError):
                        pass
                deadline = time.monotonic() + 5
                while len(counts(db)) != 12 or any(row[0] == 'intent' for row in counts(db)):
                    assert time.monotonic() < deadline, counts(db)
                    time.sleep(.02)
                assert all(row[0] == 'unknown' and row[1] is None for row in counts(db)[-2:])
                with sqlite3.connect(db) as connection:
                    connection.execute("CREATE TRIGGER reject_unexpected BEFORE INSERT ON attempts WHEN NEW.state='unknown' BEGIN SELECT RAISE(ABORT,'synthetic fault'); END")
                with dial(ports['data'], headers=headers) as sock:
                    assert turn(sock, dict(model='synthetic-text', input='before-storage-fault'))[-1]['type'] == 'response.completed'
                    send(sock, dict(type='synthetic.spawn'), masked=True)
                    try:
                        for _ in range(4):
                            opcode, body = receive(sock)
                            if opcode == 8:
                                break
                            assert opcode == 1 and json.loads(body)['type'] == 'error'
                        else:
                            raise AssertionError('No close after unadmitted generation')
                    except (EOFError, ConnectionResetError):
                        pass
                assert len(counts(db)) == 13 and provider.creates == before + 3
                process.terminate()
                assert process.wait(10) == 0
                logs = process.stdout.read()
                for name in ('synthetic.unbound', 'synthetic.future', 'synthetic.generation', 'synthetic.burst', 'x-codex-future-header'):
                    assert ('protocol_name=' + name).encode() in logs
                assert b'outcome=recorded_unknown' in logs and b'outcome=unknown_record_failed' in logs
                assert b'client_category=other' in logs and b'client_version=unknown' in logs
                assert PRIVATE.encode() not in logs and TOKEN.encode() not in logs and temporary.encode() not in logs
                print('PASS: native Cancel before/after terminal, Drain, ended/foreign IDs, multi-lane, unknown controls, rate rejection, terminal ledger, unadmitted unknown without replay, prefix handshake and content-free logs')
            finally:
                stop(process)
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(3)


if __name__ == '__main__':
    main()
