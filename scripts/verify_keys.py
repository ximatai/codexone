#!/usr/bin/env python3
"""Managed Keys via real loopback admin/data HTTP and RFC6455, without accounts or personal state."""
import argparse
import concurrent.futures
import http.client
from http.server import ThreadingHTTPServer
import json
import os
import re
import subprocess
from pathlib import Path
import sqlite3
import socket
import time
import tempfile
import threading
from verify_protocol import Upstream, TOKEN, start, stop, latest
from verify_websocket import Provider, dial, turn

ADMIN = 'synthetic-admin-credential-for-local-key-tests'
LIMITS = dict(requests=100, active=4, unresolved=8, budgetMicros=1000000, unresolvedMicros=1000000)


def call(port, method, path, body=None, token=ADMIN, extra=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    headers = {'Content-Type': 'application/json'}
    if token is not None:
        headers['Authorization'] = 'Bearer ' + token
    headers.update(extra or {})
    connection.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    response = connection.getresponse()
    result = response.status, json.loads(response.read())
    assert response.getheader('cache-control') == 'no-store'
    connection.close()
    return result


class BlockingUpstream(Upstream):
    def do_POST(self):
        if self.server.hold_next:
            self.server.hold_next = False
            self.server.entered.set()
            assert self.server.release.wait(5)
        super().do_POST()


def create(port, principal='p', models=None, limits=None):
    status, document = call(port, 'POST', '/api/keys', dict(principal=principal, models=models or ['synthetic-text'], limits=limits or LIMITS))
    assert status == 201
    secret = document['secret']
    assert secret.startswith('co1_') and len(secret) == 47
    assert 'secret' not in document['key'] and 'digest' not in document['key']
    return document['key'], secret


def update(port, key, **changes):
    body = {name: key[name] for name in ('revision', 'enabled', 'models', 'limits')}
    body.update(changes)
    return call(port, 'PUT', '/api/keys/' + key['id'], body)


def shutdown(process, root, secrets):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=10)
        output = process.stdout.read(131072)
        assert len(output) < 131072 and str(root).encode() not in output
        assert all(secret.encode() not in output for secret in secrets + [ADMIN])
        assert re.search(rb"(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}", output) is None
        assert process.returncode == 0
    finally:
        stop(process)



def verify_slow_admin(port):
    with socket.create_connection(('127.0.0.1', port), timeout=13) as sock:
        sock.sendall(('POST /api/keys HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ' + ADMIN +
                      '\r\nContent-Type: application/json\r\nContent-Length: 8000\r\n\r\n{').encode())
        done = threading.Event()
        def dribble():
            while not done.wait(0.2):
                try:
                    sock.sendall(b' ')
                except OSError:
                    return
        sender = threading.Thread(target=dribble)
        sender.start()
        started = time.monotonic()
        try:
            response = bytearray()
            while True:
                try:
                    part = sock.recv(4096)
                except ConnectionResetError:
                    break
                if not part:
                    break
                response.extend(part)
                assert len(response) < 16384
            assert not response, 'Incomplete admin body must close before routing or dispatch'
            assert 9 <= time.monotonic() - started < 12
            assert ADMIN.encode() not in response
        finally:
            done.set()
            sender.join(timeout=2)
            assert not sender.is_alive()


def verify_admin_capacity(port):
    sockets = []
    try:
        for _ in range(32):
            sockets.append(socket.create_connection(('127.0.0.1', port), timeout=2))
        time.sleep(0.1)
        with socket.create_connection(('127.0.0.1', port), timeout=2) as extra:
            try:
                assert extra.recv(1) == b''
            except ConnectionResetError:
                pass
    finally:
        for sock in sockets:
            sock.close()
    deadline = time.monotonic() + 3
    while True:
        try:
            assert call(port, 'GET', '/api/keys')[0] == 200
            break
        except (ConnectionError, http.client.RemoteDisconnected):
            assert time.monotonic() < deadline
            time.sleep(0.05)


def verify_migration(binary):
    with tempfile.TemporaryDirectory(prefix='codexone-key-migration-') as temporary:
        root = Path(temporary)
        config = root / 'legacy.json'
        import hashlib
        config.write_text(json.dumps(dict(principal='p', keyID='k', keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
            namespace='synthetic', identity='i', reservedMicros=0,
            models=[dict(id='synthetic-text', inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
            upstreamBaseURL='http://127.0.0.1:9/v1')))
        config.chmod(0o600)
        process, _ = start(binary, config, root)
        environment = dict(PATH=os.defpath, CODEXONE_DATA_DIRECTORY=str(root / 'state'))
        try:
            locked = subprocess.run([binary, '--migrate'], env=environment, capture_output=True, timeout=10)
            assert locked.returncode != 0 and str(root).encode() not in locked.stderr
        finally:
            stop(process)
        path = root / 'state/core.sqlite'
        with sqlite3.connect(path) as db:
            db.executescript('DROP TABLE request_diagnostics; DROP TABLE account_model_health; DROP TABLE health_models; DROP TABLE account_health; DROP TABLE account_quota; DROP INDEX attempts_created; DROP INDEX attempts_request; ALTER TABLE attempts DROP COLUMN request_id; ALTER TABLE attempts DROP COLUMN outcome_json; ALTER TABLE attempts DROP COLUMN created_at_epoch; DROP TABLE account_events; DROP TABLE accounts; DROP TABLE key_events; DROP TABLE managed_keys; DROP INDEX attempts_key; DROP TABLE maintenance_events; DROP TABLE maintenance_state; PRAGMA user_version=1;')
        refused = subprocess.run([binary], env=environment, capture_output=True, timeout=10)
        assert refused.returncode != 0 and str(root).encode() not in refused.stderr
        migrated = subprocess.run([binary, '--migrate'], env=environment, capture_output=True, timeout=10)
        assert migrated.returncode == 0 and str(root).encode() not in migrated.stdout + migrated.stderr
        backups = list((root / 'state').glob('*.pre-v7-*.sqlite'))
        assert len(backups) == 1 and backups[0].stat().st_mode & 0o777 == 0o600
        with sqlite3.connect(backups[0]) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == 1
        with sqlite3.connect(path) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == 7
        # check-config validates the independent administrator credential without creating a DB.
        admin = root / 'admin'
        admin.write_text(TOKEN)
        admin.chmod(0o600)
        same = subprocess.run([binary, '--check-config'], env={**environment, 'CODEXONE_IDENTITY_CONFIG': str(config),
                              'CODEXONE_ADMIN_TOKEN_FILE': str(admin)}, capture_output=True, timeout=10)
        assert same.returncode != 0
        assert TOKEN.encode() not in same.stdout + same.stderr and str(root).encode() not in same.stdout + same.stderr
        admin.unlink()
        os.mkfifo(admin, 0o600)
        fifo = subprocess.run([binary, '--check-config'], env={**environment, 'CODEXONE_IDENTITY_CONFIG': str(config),
                              'CODEXONE_ADMIN_TOKEN_FILE': str(admin)}, capture_output=True, timeout=3)
        assert fifo.returncode != 0 and str(root).encode() not in fifo.stdout + fifo.stderr
        print('PASS: offline migration rejects a live owner and normal v1 startup, creates private consistent backup; admin/data credential reuse fails closed')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    verify_migration(binary)
    for transport, handler in [('http', BlockingUpstream), ('websocket', Provider)]:
        provider = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        provider.daemon_threads = True
        provider.calls = provider.connections = 0
        provider.guard = threading.Lock()
        provider.cancelled = threading.Event()
        provider.stalled = threading.Event()
        provider.entered = threading.Event()
        provider.release = threading.Event()
        provider.hold_next = False
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix='codexone-keys-') as temporary:
                root = Path(temporary)
                admin = root / 'admin-token'
                admin.write_text(ADMIN)
                admin.chmod(0o600)
                config = root / 'config.json'
                config.write_text(json.dumps(dict(managedKeys=True, namespace='synthetic', identity='i',
                    models=[dict(id=model, inputMicrosPerMillion=0, outputMicrosPerMillion=0,
                                 catalog=dict(baseInstructions='Explicit synthetic fixture guidance'))
                            for model in ['synthetic-text', 'synthetic-other']],
                    reservedMicros=1, upstreamBaseURL=f'http://127.0.0.1:{provider.server_port}/v1', upstreamTransport=transport)))
                config.chmod(0o600)
                process, ports = start(binary, config, root, admin_token_file=admin)
                secrets = []
                request = dict(model='synthetic-text', input='synthetic', stream=False)
                db_path = root / 'state/core.sqlite'
                try:
                    if transport == 'http':
                        verify_slow_admin(ports['admin'])
                        verify_admin_capacity(ports['admin'])
                        assert call(ports['admin'], 'POST', '/api/keys', 'x' * 8193)[0] == 413
                    for token in (None, TOKEN):
                        assert call(ports['admin'], 'GET', '/api/keys', token=token)[0] == 401
                    for extra in ({'Origin': 'http://127.0.0.1'}, {'Sec-Fetch-Site': 'same-origin'}, {'Cookie': 'synthetic=1'}):
                        assert call(ports['admin'], 'GET', '/api/keys', extra=extra)[0] == 403
                    assert call(ports['data'], 'GET', '/v1/models', token=ADMIN)[0] == 401
                    a, a_secret = create(ports['admin']); secrets.append(a_secret)
                    b, b_secret = create(ports['admin'], principal='other'); secrets.append(b_secret)
                    for prefix in ('/v1', '/backend-api/codex'):
                        status, document = call(ports['data'], 'GET', prefix + '/models?client_version=0.163.0', token=a_secret)
                        assert status == 200 and [m['id'] for m in document['data']] == ['synthetic-text']
                        assert [m['slug'] for m in document['models']] == ['synthetic-text']
                        assert call(ports['data'], 'POST', prefix + '/responses', {**request, 'model': 'synthetic-other'}, token=a_secret)[0] == 403
                    assert provider.calls == 0
                    empty, empty_secret = create(ports['admin'], principal='empty', models=['synthetic-unroutable'])
                    secrets.append(empty_secret)
                    assert call(ports['data'], 'GET', '/v1/models', token=empty_secret)[1]['data'] == []
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=empty_secret)[0] == 403
                    assert call(ports['admin'], 'GET', '/api/keys?after=bad%20cursor')[0] == 400
                    assert update(ports['admin'], a, revision=99)[0] == 409
                    # Metadata changes cannot silently transfer an existing key to another principal.
                    invalid = dict(revision=1, enabled=True, models=a['models'], limits=LIMITS, principal='other')
                    assert call(ports['admin'], 'PUT', '/api/keys/' + a['id'], invalid)[0] == 400
                    if transport == 'http':
                        status, first = call(ports['data'], 'POST', '/v1/responses', request, token=a_secret)
                        assert status == 200
                        latest(db_path, 'settled')
                        before = provider.calls
                        follow = {**request, 'previous_response_id': first['id']}
                        assert call(ports['data'], 'POST', '/v1/responses', follow, token=b_secret)[0] == 400
                        assert provider.calls == before
                        status, rotated = call(ports['admin'], 'POST', '/api/keys/' + a['id'] + '/rotate', {'revision': 1})
                        assert status == 201 and rotated['key']['principal'] == a['principal']
                        secrets.append(rotated['secret'])
                        assert call(ports['data'], 'POST', '/v1/responses', request, token=a_secret)[0] == 401
                        assert call(ports['data'], 'POST', '/v1/responses', follow, token=rotated['secret'])[0] == 200
                        latest(db_path, 'settled')
                        assert call(ports['admin'], 'POST', '/api/keys/' + a['id'] + '/rotate', {'revision': 1})[0] == 409
                        # Revocation only stops new admission; a turn already dispatched still settles.
                        provider.hold_next = True
                        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                            running = pool.submit(call, ports['data'], 'POST', '/v1/responses', request, b_secret)
                            assert provider.entered.wait(4)
                            assert update(ports['admin'], b, enabled=False)[0] == 200
                            provider.release.set()
                            assert running.result(timeout=6)[0] == 200
                        latest(db_path, 'settled')
                    else:
                        with dial(ports['data'], token=a_secret) as downstream:
                            assert turn(downstream, request)[-1]['type'] == 'response.completed'
                            latest(db_path, 'settled')
                            count = provider.calls
                            assert update(ports['admin'], a, models=['synthetic-other'])[0] == 200
                            events = turn(downstream, request)
                            assert events[-1]['type'] == 'error' and events[-1]['error']['code'] == 'model_not_allowed'
                            assert provider.calls == count
                        with dial(ports['data'], token=b_secret) as downstream:
                            assert turn(downstream, request)[-1]['type'] == 'response.completed'
                            latest(db_path, 'settled')
                            count = provider.calls
                            assert update(ports['admin'], b, enabled=False)[0] == 200
                            events = turn(downstream, request)
                            assert events[-1]['type'] == 'error' and events[-1]['error']['code'] == 'invalid_api_key'
                            assert provider.calls == count
                    limited, limited_secret = create(ports['admin'], principal='limited', limits={**LIMITS, 'requests': 1})
                    secrets.append(limited_secret)
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=limited_secret)[0] == 200
                    latest(db_path, 'settled')
                    count = provider.calls
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=limited_secret)[0] == 429
                    assert provider.calls == count
                    status, rotation = call(ports['admin'], 'POST', '/api/keys/' + limited['id'] + '/rotate', {'revision': 1})
                    assert status == 201 and rotation['key']['id'] == limited['id'] and rotation['key']['revision'] == 2
                    secrets.append(rotation['secret'])
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=limited_secret)[0] == 401
                    limited_secret = rotation['secret']
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=limited_secret)[0] == 429
                    status, listing = call(ports['admin'], 'GET', '/api/keys')
                    assert status == 200 and 'secret' not in json.dumps(listing) and 'digest' not in json.dumps(listing)
                    assert listing['nextCursor'] is None
                    # Capacity injection simulates a full historical audit without paid or external traffic.
                    with sqlite3.connect(db_path) as db:
                        remaining = 4096 - db.execute('SELECT COUNT(*) FROM key_events').fetchone()[0]
                        db.execute("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<?) INSERT INTO key_events SELECT 'capacity-'||i,?,1,'synthetic',1,'{}' FROM n", (remaining, empty['id']))
                    assert update(ports['admin'], empty, enabled=True)[0] == 503
                    status, revoked = update(ports['admin'], empty, enabled=False)
                    assert status == 200 and not revoked['key']['enabled']
                    assert call(ports['data'], 'GET', '/v1/models', token=empty_secret)[0] == 401
                    assert update(ports['admin'], revoked['key'], enabled=False)[0] == 503
                    assert call(ports['data'], 'GET', '/health/ready', token=None)[0] == 200
                    with sqlite3.connect(db_path) as db:
                        assert db.execute('PRAGMA user_version').fetchone()[0] == 7
                        assert db.execute('SELECT COUNT(*) FROM key_events').fetchone()[0] >= 4
                        assert db.execute("SELECT COUNT(*) FROM attempts WHERE state='settled'").fetchone()[0] >= 3
                finally:
                    shutdown(process, root, secrets)
                process, ports = start(binary, config, root, admin_token_file=admin)
                try:
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=b_secret)[0] == 401
                    assert call(ports['data'], 'POST', '/v1/responses', request, token=limited_secret)[0] == 429
                    for path in (root / 'state').glob('core.sqlite*'):
                        assert all(secret.encode() not in path.read_bytes() for secret in secrets + [ADMIN])
                finally:
                    shutdown(process, root, secrets)
                print(f'PASS: {transport} managed Keys: independent admin auth, catalog/execution, principal isolation, live revocation, rotation/CAS, limits, restart and private storage')
        finally:
            provider.release.set()
            provider.shutdown()
            provider.server_close()


if __name__ == '__main__':
    main()
