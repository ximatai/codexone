#!/usr/bin/env python3
"""Independent synthetic legacy store -> actual gateway -> conservative cutback.

The legacy fixture is deliberately not a CodexLB compatibility implementation.
No credential import, real service, Desktop or paid provider is involved.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import threading
import time

from verify_admin import running_admin
from verify_keys import create, shutdown, call as api_call
from verify_protocol import latest, start

OLD_TOKEN = 'synthetic-legacy-client-token'


@contextmanager
def serving(handler):
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=3)
        assert not worker.is_alive()


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def execution_truth(connection):
    return {
        'attempts': connection.execute('SELECT * FROM attempts ORDER BY id').fetchall(),
        'evidence': connection.execute('SELECT * FROM evidence ORDER BY attempt,revision').fetchall(),
        'bindings': connection.execute('SELECT * FROM bindings ORDER BY principal,namespace,identity,object_type,raw_id').fetchall(),
    }


def call(port, token, prompt='synthetic', prefix='/v1'):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        connection.request('POST', prefix + '/responses', json.dumps(
            {'model': 'synthetic-text', 'input': prompt, 'stream': prompt == 'abrupt'}),
            {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
             'Host': 'gateway.example.invalid'})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def verify(binary, previous_binary=None):
    with running_admin(binary) as f:
        old = f.root / 'synthetic-legacy.sqlite'
        with database(old) as db:
            db.executescript('CREATE TABLE baseline(requests INTEGER,spent INTEGER,unknown_count INTEGER,unknown_micros INTEGER);'
                             'INSERT INTO baseline VALUES(97,980,1,7);'
                             'CREATE TABLE receipts(id INTEGER PRIMARY KEY,kind TEXT);'
                             "CREATE UNIQUE INDEX unique_cutback ON receipts(kind) WHERE kind='cutback-new-interval-reconciled';")
        old.chmod(0o600)
        entered, release = threading.Event(), threading.Event()
        legacy_accepting = threading.Event(); legacy_accepting.set()
        old_digest = hashlib.sha256(OLD_TOKEN.encode()).digest()

        class Legacy(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_POST(self):
                if not legacy_accepting.is_set():
                    self.send_error(503); return
                # Only a digest can be exported; the old plaintext Key is not migrated.
                if hashlib.sha256(self.headers.get('Authorization', '').removeprefix('Bearer ').encode()).digest() != old_digest:
                    self.send_error(401); return
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 4096:
                    self.send_error(413); return
                with database(old) as db:
                    used, spent, unknown_count, unknown_micros = db.execute('SELECT * FROM baseline').fetchone()
                if used >= 100 or spent + unknown_micros >= 1000 or unknown_count >= 8:
                    self.send_error(429); return
                body = json.loads(self.rfile.read(length))
                if body['input'] == 'held':
                    entered.set()
                    assert release.wait(5)
                with database(old) as db:
                    db.execute("INSERT INTO receipts(kind) VALUES('settled')")
                    db.execute('UPDATE baseline SET requests=requests+1,spent=spent+3')
                output = json.dumps({'id': 'synthetic-legacy-output', 'status': 'completed'}).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(output)))
                self.end_headers(); self.wfile.write(output)

        class RouteState:
            def __init__(self, port):
                self.condition = threading.Condition()
                self.port, self.paused, self.active = port, False, 0
            def switch(self, port, timeout=2):
                with self.condition:
                    self.paused = True
                    if not self.condition.wait_for(lambda: self.active == 0, timeout):
                        raise TimeoutError('Cutover remains paused while requests are active')
                    self.port, self.paused = port, False

        with serving(Legacy) as legacy:
            route = RouteState(legacy.server_port)

            class Proxy(BaseHTTPRequestHandler):
                def log_message(self, *_): pass
                def do_POST(self):
                    length = int(self.headers.get('Content-Length', '0'))
                    if self.path not in ('/v1/responses', '/backend-api/codex/responses') or not 0 < length <= 4096:
                        self.send_error(400); return
                    with route.condition:
                        if route.paused or route.active >= 4:
                            self.send_error(503); return
                        route.active += 1
                        port = route.port
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
                    try:
                        # Exactly one forwarding attempt. No fallback to the other service.
                        connection.request('POST', self.path, self.rfile.read(length),
                            {'Authorization': self.headers.get('Authorization', ''), 'Content-Type': 'application/json'})
                        response = connection.getresponse(); output = response.read(8_388_609)
                        assert len(output) <= 8_388_608
                        self.send_response(response.status)
                        self.send_header('Content-Length', str(len(output)))
                        self.end_headers(); self.wfile.write(output)
                    finally:
                        connection.close()
                        with route.condition:
                            route.active -= 1
                            route.condition.notify_all()

            with serving(Proxy) as proxy, ThreadPoolExecutor(max_workers=1) as executor:
                held = executor.submit(call, proxy.server_port, OLD_TOKEN, 'held')
                assert entered.wait(3)
                try:
                    route.switch(f.ports['data'], timeout=0.05)
                    raise AssertionError('Cutover bypassed an active old request')
                except TimeoutError: pass
                assert call(proxy.server_port, OLD_TOKEN)[0] == 503
                assert route.port == legacy.server_port
                release.set(); assert held.result(timeout=5)[0] == 200
                # Pause after the old side drains, then take an independent consistent backup.
                with route.condition: route.paused = True
                backup = f.root / 'synthetic-legacy-backup.sqlite'
                with database(old) as source, database(backup) as target:
                    source.backup(target)
                backup.chmod(0o600)
                old_hash = hashlib.sha256(old.read_bytes()).digest()
                backup_hash = hashlib.sha256(backup.read_bytes()).digest()
                with database(old) as db:
                    baseline = db.execute('SELECT * FROM baseline').fetchone()
                # This single-principal fixture carries old exposure by reducing fresh grants.
                # Multi-principal/unknown attribution requires a separately approved baseline.
                limits = dict(requests=100-baseline[0], active=4, unresolved=8-baseline[2],
                              budgetMicros=1000-baseline[1]-baseline[3], unresolvedMicros=1000-baseline[3])
                key, fresh = create(f.ports['admin'], principal='synthetic-migrated', limits=limits)
                f.secrets.append(fresh)
                legacy_accepting.clear()
                assert call(legacy.server_port, OLD_TOKEN)[0] == 503
                route.switch(f.ports['data'])
                before = f.provider.calls
                assert call(proxy.server_port, OLD_TOKEN)[0] == 401
                assert f.provider.calls == before
                assert call(proxy.server_port, fresh, prefix='/backend-api/codex')[0] == 200
                latest(f.root / 'state/core.sqlite', 'settled')
                assert call(proxy.server_port, fresh, prompt='abrupt')[0] == 200
                latest(f.root / 'state/core.sqlite', 'unknown')
                assert f.provider.calls == before + 2
                assert key['limits'] == limits
                assert call(proxy.server_port, fresh)[0] == 429
                assert f.provider.calls == before + 2
                assert hashlib.sha256(old.read_bytes()).digest() == old_hash
                # No old object ownership is imported and no new provider token is shared.
                with database(f.root / 'state/core.sqlite') as db:
                    assert db.execute('SELECT COUNT(*) FROM accounts').fetchone()[0] == 0
                    rows = db.execute('SELECT state,reserved,estimated FROM attempts ORDER BY rowid').fetchall()
                    assert len(rows) == 2 and [row[0] for row in rows] == ['settled', 'unknown']
                with route.condition: route.paused = True
                assert call(proxy.server_port, fresh)[0] == 503
                shutdown(f.process, f.root, f.secrets); f.process = None
                if previous_binary:
                    assert hashlib.sha256(Path(binary).read_bytes()).digest() != hashlib.sha256(Path(previous_binary).read_bytes()).digest()
                    with database(f.root / 'state/core.sqlite') as db:
                        durable = execution_truth(db)
                        assert db.execute("SELECT COUNT(*) FROM evidence JOIN attempts ON evidence.attempt=attempts.id WHERE attempts.state='settled'").fetchone()[0] > 0
                    for executable in (previous_binary, binary):
                        f.process, peer_ports = start(executable, f.config, f.root, admin_token_file=f.admin, web_directory=f.web_directory)
                        assert api_call(peer_ports['data'], 'GET', '/v1/models', token=fresh)[0] == 200
                        assert call(peer_ports['data'], fresh)[0] == 429
                        assert f.provider.calls == before + 2
                        with database(f.root / 'state/core.sqlite') as db:
                            assert execution_truth(db) == durable
                        shutdown(f.process, f.root, f.secrets); f.process = None
                    print('PASS: distinct actual compatible binary rollback/re-upgrade preserves genuine settled/unknown evidence, object ownership and exhausted Key quota without dispatch')
                stable_new_hash = hashlib.sha256((f.root / 'state/core.sqlite').read_bytes()).digest()
                # Cutback receipt explicitly adds every new request and unknown exposure.
                missing = [row for row in rows if row[0] == 'unknown']
                with database(old) as db:
                    db.execute('UPDATE baseline SET requests=requests+?,spent=spent+?,unknown_count=unknown_count+?,unknown_micros=unknown_micros+?',
                               (len(rows), sum(row[2] for row in rows if row[0] == 'settled'), len(missing), sum(row[1] for row in missing)))
                    db.execute("INSERT INTO receipts(kind) VALUES('cutback-new-interval-reconciled')")
                    carried = db.execute('SELECT * FROM baseline').fetchone()
                assert carried[0] == baseline[0]+2 and carried[2] == baseline[2]+1
                assert carried[3] == baseline[3]+sum(row[1] for row in missing)
                # A repeated audit receipt must roll back instead of charging twice.
                with database(old) as db:
                    try:
                        with db:
                            db.execute('UPDATE baseline SET requests=requests+2')
                            db.execute("INSERT INTO receipts(kind) VALUES('cutback-new-interval-reconciled')")
                        raise AssertionError('Repeated cutback receipt was accepted')
                    except sqlite3.IntegrityError: pass
                    assert db.execute('SELECT * FROM baseline').fetchone() == carried
                legacy_accepting.set()
                route.switch(legacy.server_port)
                assert call(proxy.server_port, fresh)[0] == 401
                assert call(proxy.server_port, OLD_TOKEN)[0] == 429
                assert f.provider.calls == before + 2
                with database(f.root / 'state/core.sqlite') as db:
                    assert db.execute('SELECT state,reserved,estimated FROM attempts ORDER BY rowid').fetchall() == rows
                assert hashlib.sha256(backup.read_bytes()).digest() == backup_hash
                assert hashlib.sha256((f.root / 'state/core.sqlite').read_bytes()).digest() == stable_new_hash
                print('PASS: synthetic independent legacy backup/drain, unchanged route/prefix, explicit Key replacement and conservative baseline; actual gateway settled/unknown interval preserved on audited cutback without replay')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--previous-binary', type=Path)
    args = parser.parse_args()
    verify(str(args.binary.resolve()), str(args.previous_binary.resolve()) if args.previous_binary else None)


if __name__ == '__main__':
    main()
