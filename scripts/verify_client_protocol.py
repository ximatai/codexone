#!/usr/bin/env python3
"""Synthetic native WS controls, late acknowledgements and unexpected generation ledger."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import socket
import tempfile
import threading
import time
from verify_protocol import TOKEN, start, stop
from verify_websocket import dial, send, receive, turn
from verify_admin import request, document
from verify_keys import ADMIN

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
        for name in ('x-codex-beta-features', 'x-codex-window-id', 'x-codex-parent-thread-id'):
            assert self.headers[name] == 'synthetic-known'
        key = self.headers['Sec-WebSocket-Key']
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode())
        self.end_headers()
        pending = {}
        recent = None
        writes = threading.Lock()
        closed = threading.Event()
        settlements = []

        def emit(value):
            with writes:
                send(self.connection, value)

        def complete(items):
            # A delayed lane must not block this connection's sole request reader.
            until = time.monotonic() + 5
            while not self.server.settle_release.is_set():
                if closed.wait(.01):
                    return
                assert time.monotonic() < until, 'Synthetic settlement gate timed out'
            try:
                for item in items:
                    emit(item)
            except (EOFError, ConnectionResetError, BrokenPipeError, OSError):
                pass

        try:
            while True:
                opcode, data = receive(self.connection, masked=True)
                if opcode == 8:
                    return
                value = json.loads(data)
                kind = value['type']
                if kind == 'response.interrupt':
                    with self.server.guard:
                        self.server.interrupts += 1
                        self.server.interrupt_bytes.append(value)
                    response, lane, prompt = pending.pop(value['response_id'])
                    if prompt.startswith('settlement-'):
                        self.server.interrupted.set()
                        if prompt == 'settlement-abrupt':
                            time.sleep(.2)
                            return
                        if prompt == 'settlement-error':
                            emit(dict(type='error', response_id=response['id'],
                                error=dict(code='synthetic_interrupt_unsupported', message=PRIVATE), **lane))
                            continue
                        if prompt == 'settlement-unknown':
                            emit(dict(type='synthetic.interrupt_unknown', response_id=response['id'], **lane))
                        if prompt in ('settlement-timeout', 'settlement-shutdown', 'settlement-unknown'):
                            self.connection.settimeout(15)
                            assert self.connection.recv(1) == b''
                            return
                    ack = dict(type='response.interrupt.accepted', response_id=response['id'])
                    done = dict(type='response.completed', response=response, **lane)
                    items = [done, ack] if prompt == 'cancel-after' else [ack, done]
                    if prompt.startswith('settlement-'):
                        worker = threading.Thread(target=complete, args=(items,))
                        settlements.append(worker)
                        worker.start()
                    else:
                        for item in items:
                            emit(item)
                    recent = response['id']
                elif kind != 'response.create':
                    with self.server.guard:
                        self.server.controls += 1
                        self.server.control_bytes.append(data)
                    if kind == 'synthetic.spawn':
                        emit(dict(type='response.created', response=dict(id='synthetic-unadmitted', status='in_progress', output=[])))
                    else:
                        emit(dict(type='synthetic.echo', response_id=recent, payload=value.get('payload')))
                else:
                    with self.server.guard:
                        self.server.creates += 1
                        index = self.server.creates
                    response = dict(id=f'synthetic-response-{index}', status='completed', output=[],
                        usage=dict(input_tokens=5, output_tokens=3, input_tokens_details=dict(cached_tokens=0)))
                    lane = dict(stream_id=value['stream_id']) if 'stream_id' in value else {}
                    if value['input'] == 'settlement-late-created':
                        self.server.dispatched.set()
                        time.sleep(.2)
                    emit(dict(type='response.created', response={**response, 'status': 'in_progress', 'usage': None}, **lane))
                    if value['input'] in ('cancel-before', 'cancel-after', 'drain') or value['input'].startswith('settlement-'):
                        pending[response['id']] = response, lane, value['input']
                    else:
                        emit(dict(type='response.completed', response=response, **lane))
                        recent = response['id']
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            closed.set()
            for worker in settlements:
                worker.join(1)
                assert not worker.is_alive()
            self.close_connection = True


def counts(db):
    with sqlite3.connect(db) as connection:
        return connection.execute('SELECT state,usage_json,admission_json,outcome_json FROM attempts ORDER BY rowid').fetchall()


def verify_settlement(binary, provider, directory, configuration, headers):
    directory.mkdir()
    config = directory / 'identity.json'
    config.write_text(json.dumps(configuration))
    config.chmod(0o600)
    process, ports = start(binary, config, directory)
    db = directory / 'state/core.sqlite'
    try:
        def begin_settlement(prompt, interrupt=True, queued=False, wait_for_interrupt=True):
            sock = dial(ports['data'], headers=headers)
            send(sock, dict(type='response.create', model='synthetic-text', input=prompt), masked=True)
            created = event(sock)
            assert created['type'] == 'response.created', created
            rid = created['response']['id']
            if interrupt:
                provider.interrupted.clear()
                send(sock, dict(type='response.interrupt', response_id=rid), masked=True)
                if wait_for_interrupt:
                    assert provider.interrupted.wait(3)
            if queued:
                send(sock, dict(type='response.create', model='synthetic-text', input='must-not-dispatch'), masked=True)
            sock.close()

        def await_rows(total, states, timeout=5):
            until = time.monotonic() + timeout
            while True:
                rows = counts(db)
                if len(rows) == total and [row[0] for row in rows[-len(states):]] == states:
                    return rows[-len(states):]
                assert time.monotonic() < until, [row[0] for row in rows]
                time.sleep(.02)

        def assert_connection_slots_released():
            until = time.monotonic() + 3
            while True:
                sockets = []
                try:
                    for _ in range(8):
                        sockets.append(dial(ports['data'], headers=headers))
                    return
                except (AssertionError, EOFError, ConnectionResetError, socket.timeout):
                    assert time.monotonic() < until, 'Connection slots were not released'
                    time.sleep(.02)
                finally:
                    for sock in sockets:
                        sock.close()

        baseline = len(counts(db))
        before = provider.creates
        interrupt_before = provider.interrupts
        # No caller interrupt: all eight closed downstreams retain their connection slots.
        for _ in range(8):
            begin_settlement('settlement-success', interrupt=False)
        assert len(counts(db)) == baseline + 8
        assert all(row[0] == 'intent' for row in counts(db)[-8:])
        rejected = False
        try:
            with dial(ports['data'], headers=headers, timeout=.25):
                pass
        except (AssertionError, EOFError, ConnectionResetError, socket.timeout):
            rejected = True
        assert rejected, 'Settlement released connection capacity early'
        provider.settle_release.set()
        settled = await_rows(baseline + 8, ['settled'] * 8)
        assert provider.interrupts == interrupt_before + 8
        assert all(set(value) == {'type', 'response_id'} for value in provider.interrupt_bytes[-8:])
        assert all(json.loads(row[1])['inputTokens'] == 5 and json.loads(row[1])['outputTokens'] == 3
                   and json.loads(row[1])['estimatedMicros'] == 8 for row in settled)
        assert all(json.loads(row[3])['kind'] == 'cancelled'
                   and json.loads(row[3])['failure'] == 'client_cancelled' for row in settled)
        assert_connection_slots_released()
        # Every failure retains unknown exposure and never replays the create.
        total = baseline + 8
        for prompt in ('settlement-abrupt', 'settlement-error', 'settlement-timeout', 'settlement-unknown'):
            began = time.monotonic()
            interrupts = provider.interrupts
            begin_settlement(prompt, interrupt=False)
            total += 1
            row = await_rows(total, ['unknown'], timeout=12)[0]
            assert row[1] is None and json.loads(row[3])['failure'] == 'client_cancelled'
            assert provider.interrupts == interrupts + 1
            if prompt in ('settlement-timeout', 'settlement-unknown'):
                assert 9.5 <= time.monotonic() - began < 12
            # A fresh connection/turn proves connection/lane/local permits released after failure.
            with dial(ports['data'], headers=headers) as sock:
                assert turn(sock, dict(model='synthetic-text', input='after-settlement'))[-1]['type'] == 'response.completed'
            total += 1
            await_rows(total, ['settled'])
            assert_connection_slots_released()
        # An already forwarded interrupt must not be sent again after downstream closure.
        provider.settle_release.clear()
        interrupted = provider.interrupts
        begin_settlement('settlement-success', queued=True)
        total += 1
        time.sleep(.1)
        assert provider.interrupts == interrupted + 1
        provider.settle_release.set()
        row = await_rows(total, ['settled'])[0]
        assert json.loads(row[3])['failure'] == 'client_cancelled'
        assert provider.interrupts == interrupted + 1
        # Close immediately after writing the caller interrupt: a suspended write cannot duplicate it.
        interrupted = provider.interrupts
        begin_settlement('settlement-success', wait_for_interrupt=False)
        total += 1
        await_rows(total, ['settled'])
        assert provider.interrupts == interrupted + 1
        # Wait for a dispatched turn's identity rather than broadcast an interrupt without an ID.
        provider.dispatched.clear()
        sock = dial(ports['data'], headers=headers)
        send(sock, dict(type='response.create', model='synthetic-text', input='settlement-late-created'), masked=True)
        assert provider.dispatched.wait(3)
        sock.close()
        total += 1
        await_rows(total, ['settled'])
        # Before any create, and after a completed turn, disconnect sends no extra control.
        interrupted = provider.interrupts
        with dial(ports['data'], headers=headers):
            pass
        with dial(ports['data'], headers=headers) as sock:
            assert turn(sock, dict(model='synthetic-text', input='already-terminal'))[-1]['type'] == 'response.completed'
        total += 1
        await_rows(total, ['settled'])
        time.sleep(.1)
        assert provider.interrupts == interrupted
        # A failed lane must not cancel its sibling's settlement or target its identity.
        provider.settle_release.clear()
        sock = dial(ports['data'], headers=headers)
        ids = {}
        for lane, prompt in (('', 'settlement-error'), ('sibling', 'settlement-success')):
            send(sock, dict(type='response.create', model='synthetic-text', input=prompt,
                **(dict(stream_id=lane) if lane else {})), masked=True)
            ids[lane] = event(sock)['response']['id']
        sock.close()
        total += 2
        await_rows(total, ['unknown', 'intent'])
        provider.settle_release.set()
        await_rows(total, ['unknown', 'settled'])
        controls = {value['response_id']: value for value in provider.interrupt_bytes}
        assert controls[ids['sibling']] == dict(type='response.interrupt',
            response_id=ids['sibling'], stream_id='sibling')
        assert controls[ids['']] == dict(type='response.interrupt', response_id=ids[''])
        assert provider.creates == before + total - baseline, 'Unexpected replay'
        provider.interrupted.clear()
        begin_settlement('settlement-shutdown', interrupt=False)
        assert provider.interrupted.wait(3)
        total += 1
        began = time.monotonic()
        process.terminate()
        assert process.wait(10) == 0
        assert time.monotonic() - began < 5, 'Shutdown waited for settlement timeout'
        await_rows(total, ['unknown'])
        assert process.returncode == 0
        logs = process.stdout.read()
        assert all(secret.encode() not in logs for secret in
            (PRIVATE, TOKEN, ADMIN, 'synthetic-value', 'synthetic-gate', 'synthetic-known'))
        for name in ('x-codex-beta-features', 'x-codex-window-id', 'x-codex-parent-thread-id'):
            assert ('protocol_name=' + name).encode() not in logs
        print('PASS: gateway interrupt settles cancelled usage; exactly one targeted control; connection capacity retained; EOF/error/10s timeout/unknown preserve unknown without replay; sibling lanes and resources release; shutdown cancels drain; known headers forward without warnings')
        short_root = directory / 'short-deadline'
        short_root.mkdir()
        short_config = short_root / 'identity.json'
        short_config.write_text(json.dumps({**configuration, 'executionTimeoutSeconds': 2}))
        short_config.chmod(0o600)
        process, ports = start(binary, short_config, short_root)
        db = short_root / 'state/core.sqlite'
        began = time.monotonic()
        begin_settlement('settlement-timeout', interrupt=False)
        await_rows(1, ['unknown'], timeout=4)
        assert time.monotonic() - began < 4, 'Settlement extended the execution deadline'
        print('PASS: interrupted settlement retains the original shorter execution deadline')
    finally:
        stop(process)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    provider.daemon_threads = True
    provider.guard = threading.Lock()
    provider.creates = provider.controls = provider.interrupts = 0
    provider.control_bytes = []
    provider.interrupt_bytes = []
    provider.dispatched = threading.Event()
    provider.interrupted = threading.Event()
    provider.settle_release = threading.Event()
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-client-protocol-') as temporary:
            root = Path(temporary)
            config = root/'identity.json'
            config.write_text(json.dumps(dict(principal='synthetic-principal', keyID='synthetic-key',
                keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(), namespace='synthetic-provider', identity='synthetic-account',
                reservedMicros=10, executionTimeoutSeconds=30, dataConnections=8,
                models=[dict(id='synthetic-text', inputMicrosPerMillion=1000000, outputMicrosPerMillion=1000000)],
                upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1', upstreamTransport='websocket')))
            config.chmod(0o600)
            admin = root / "admin"
            admin.write_text(ADMIN)
            admin.chmod(0o600)
            process, ports = start(binary, config, root, admin_token_file=admin)
            db = root/'state/core.sqlite'
            try:
                headers = {'x-codex-future-header': 'synthetic-value', 'x-openai-actor-authorization': 'synthetic-gate', 'chatgpt-account-id': 'synthetic-forged'}
                headers.update({name: 'synthetic-known' for name in ('x-codex-beta-features', 'x-codex-window-id', 'x-codex-parent-thread-id')})
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
                        assert created['type'] == 'response.created', created
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
                assert all(state == 'settled' and json.loads(usage)['estimatedMicros'] == 8 for state, usage, _, _ in counts(db))
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
                attention = document(request(ports["admin"], "GET", "/api/attention",
                    headers={"Authorization": "Bearer " + ADMIN}))
                names = {item["subjectName"] for item in attention["items"]
                         if item["kind"] == "client_protocol_extension"}
                assert {"synthetic.unbound", "synthetic.future", "synthetic.generation",
                        "synthetic.burst", "x-codex-future-header"}.issubset(names)
                assert "upstream.lifecycle" not in names
                payload = json.dumps(attention)
                assert all(secret not in payload for secret in (PRIVATE, TOKEN, ADMIN, "synthetic-value", "synthetic-gate"))
                process.terminate()
                assert process.wait(10) == 0
                logs = process.stdout.read()
                for name in ('x-codex-beta-features', 'x-codex-window-id', 'x-codex-parent-thread-id'):
                    assert ('protocol_name=' + name).encode() not in logs
                for name in ('synthetic.unbound', 'synthetic.future', 'synthetic.generation', 'synthetic.burst', 'x-codex-future-header'):
                    assert ('protocol_name=' + name).encode() in logs
                assert b'outcome=recorded_unknown' in logs and b'outcome=unknown_record_failed' in logs
                assert b'client_category=other' in logs and b'client_version=unknown' in logs
                assert all(secret.encode() not in logs for secret in
            (PRIVATE, TOKEN, ADMIN, 'synthetic-value', 'synthetic-gate', 'synthetic-known')) and TOKEN.encode() not in logs and temporary.encode() not in logs
                print('PASS: native Cancel before/after terminal, Drain, ended/foreign IDs, multi-lane, unknown controls, rate rejection, terminal ledger, unadmitted unknown without replay, prefix handshake and content-free logs')
                verify_settlement(binary, provider, root / 'settlement', json.loads(config.read_text()), headers)
            finally:
                stop(process)
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(3)


if __name__ == '__main__':
    main()
