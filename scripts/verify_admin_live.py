#!/usr/bin/env python3
"""Synthetic real-process admin upgrade/frames/SQLite/data-plane observation checks."""
import argparse
import concurrent.futures
import subprocess
import base64
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import threading
import time
import tempfile
from types import SimpleNamespace
from verify_admin_round2 import port_line
from verify_admin import running_admin, login, request, document
from verify_keys import create, ADMIN, shutdown
from verify_protocol import start
from verify_websocket import dial as data_dial, Provider
from verify_websocket import exact, receive, send


def dial(f, cookie, *, origin=True, path='/api/overview/live', extra=(), host=None, receive_buffer=None):
    sock = socket.create_connection(('127.0.0.1', f.ports['admin']), timeout=12)
    if receive_buffer: sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
    headers = [('Host', host or f"127.0.0.1:{f.ports['admin']}"), ('Upgrade', 'websocket'),
               ('Connection', 'Upgrade'), ('Sec-WebSocket-Version', '13'),
               ('Sec-WebSocket-Key', base64.b64encode(os.urandom(16)).decode())]
    if cookie:
        headers.append(('Cookie', cookie))
    if origin:
        headers.append(('Origin', f.origin if origin is True else origin))
    headers.extend(extra)
    sock.sendall((f'GET {path} HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in headers) + '\r\n').encode())
    header = b''
    while not header.endswith(b'\r\n\r\n'):
        header += exact(sock, 1)
        assert len(header) < 16384
    status = int(header.split(b' ')[1])
    if status != 101:
        sock.close()
        return status, None
    assert b'sec-websocket-extensions:' not in header.lower()
    return status, sock


def frame(sock):
    while True:
        opcode, data = receive(sock)
        if opcode == 9:
            send(sock, data, opcode=10, masked=True)
        elif opcode == 10:
            continue
        elif opcode == 1:
            value = json.loads(data)
            assert len(data) <= 1048576 and value['protocol'] == 1
            value['_wireBytes'] = len(data)
            return value
        else:
            return {'close': int.from_bytes(data[:2], 'big') if len(data) >= 2 else None}


def until(sock, predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = frame(sock)
        if predicate(value):
            return value
    raise AssertionError('Expected frame did not arrive')


def verify(binary):
    measurements = {}
    with running_admin(binary, admin_live=True) as f:
        cookie, csrf = login(f)
        rss = lambda: int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(f.process.pid)]).strip()) * 1024
        measurements['rss_zero_before_bytes'] = rss()
        key, secret = create(f.ports['admin'])
        f.secrets.append(secret)
        invalid = [dict(cookie=None), dict(origin=False), dict(origin='null'), dict(origin='https://foreign.example'),
                   dict(path='/api/overview/live?x=1'), dict(host='foreign.example'),
                   dict(extra=[('Origin', f.origin)]), dict(extra=[('Cookie', cookie)]), dict(cookie=cookie + '; ' + cookie), dict(extra=[('Host', f'127.0.0.1:{f.ports["admin"]}')]), dict(extra=[('Sec-Fetch-Site', 'cross-site')]),
                   dict(extra=[('Authorization', 'Bearer ' + ADMIN)]),
                   dict(extra=[('Authorization', 'Bearer ' + secret)]), dict(extra=[('Sec-WebSocket-Protocol', 'synthetic')])]
        for change in invalid:
            options = dict(cookie=cookie); options.update(change)
            assert dial(f, **options)[0] != 101
        status, sock = dial(f, cookie, extra=[('Sec-WebSocket-Extensions', 'permessage-deflate')])
        assert status == 101
        initial = frame(sock)
        assert initial['kind'] == 'snapshot' and initial['sequence'] == 1
        assert set(initial['sections']) == {'system', 'inFlight', 'daily', 'keys', 'accounts', 'storage', 'attention', 'headroom'}
        second = dial(f, cookie)[1]
        assert frame(second)['kind'] == 'snapshot'
        assert dial(f, cookie)[0] == 429
        sockets = [sock, second]
        for _ in range(3):
            other, _ = login(f)
            for _ in range(2):
                current = dial(f, other)[1]; sockets.append(current)
                assert frame(current)['kind'] == 'snapshot'
        assert len(sockets) == 8
        ninth, _ = login(f)
        assert dial(f, ninth)[0] == 429
        assert request(f.ports['admin'], 'GET', '/api/session', cookie=cookie)[0] == 200
        measurements['rss_8_viewers_bytes'] = rss()
        # Short requests remain observable even when admission/finalization share a merge window.
        started_at = time.monotonic()
        result = request(f.ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'synthetic', 'stream': False}, headers={'Authorization': 'Bearer ' + secret})
        assert result[0] == 200
        # HTTP completion does not await the asynchronous finalizer transaction.
        commit_deadline = time.monotonic() + 5
        while True:
            with sqlite3.connect(f.root / 'state/core.sqlite') as db:
                settled = db.execute("SELECT COUNT(*) FROM attempts WHERE state='settled'").fetchone()[0]
            if settled == 1:
                break
            assert time.monotonic() < commit_deadline, ('settled_attempts', settled)
            time.sleep(.01)
        committed = time.monotonic()
        value = until(sock, lambda value: bool(value.get('sections', {}).get('inFlight', {}).get('data', {}).get('recentlyFinished')))
        received = time.monotonic()
        measurements['request_start_to_frame_ms'] = round((received - started_at) * 1000, 2)
        measurements['commit_observed_to_frame_ms'] = round((received - committed) * 1000, 2)
        recent = value['sections']['inFlight']['data']['recentlyFinished']
        assert recent[-1]['keyID'] == key['id'] and recent[-1]['outcome'] == 'succeeded'
        has_aggregate = lambda frame: any(row['admitted'] == 1 for row in frame.get('sections', {}).get('keys', {}).get('data', {}).get('keys', []))
        aggregate = value if has_aggregate(value) else until(sock, has_aggregate)
        assert aggregate['sequence'] >= value['sequence']
        measurements['commit_observed_to_aggregate_ms'] = round((time.monotonic() - committed) * 1000, 2)
        # Replacing a cookie revokes both bindings synchronously, while other sessions survive.
        fresh, _ = login(f, cookie=cookie)
        until(sock, lambda value: value.get('close') == 1008)
        until(second, lambda value: value.get('close') == 1008)
        sock.close(); second.close()
        for current in sockets[2:]: current.close()
        time.sleep(.2)
        current = dial(f, fresh)[1]; frame(current)
        send(current, bytes([3, 232]), opcode=8, masked=True)
        assert frame(current)['close'] == 1000
        current.close()
        # Forbidden application frames and fragmentation never enter an application inbox.
        for opcode, fin in [(1, True), (2, True), (0, False)]:
            current = dial(f, fresh)[1]; assert current
            frame(current)
            send(current, b'x', opcode=opcode, fin=fin, masked=True)
            try:
                assert current.recv(1) == b''
            except ConnectionResetError:
                pass
            current.close()
        # Logout and zero-viewer interval; the HTTP API remains available.
        current = dial(f, fresh)[1]; frame(current)
        session = document(request(f.ports['admin'], 'GET', '/api/session', cookie=fresh))
        assert request(f.ports['admin'], 'DELETE', '/api/session', cookie=fresh, origin=f.origin, csrf=session['csrf'])[0] == 200
        until(current, lambda value: value.get('close') == 1008); current.close()
        time.sleep(.3)
        measurements['rss_zero_viewers_after_bytes'] = rss()
        measurements['rss_8_minus_zero_bytes'] = measurements['rss_8_viewers_bytes'] - measurements['rss_zero_before_bytes']
        # Reconfigure only this synthetic process to a fake native WS provider; sessions restart empty.
        shutdown(f.process, f.root, f.secrets)
        config = json.loads(f.config.read_text()); config['upstreamTransport'] = 'websocket'; f.config.write_text(json.dumps(config))
        f.provider.RequestHandlerClass = Provider; f.provider.connections = 0; f.provider.stalled = threading.Event()
        f.process, f.ports = start(binary, f.config, f.root, admin_token_file=f.admin, web_directory=f.web_directory, admin_live=True)
        f.origin = f"http://127.0.0.1:{f.ports['admin']}"
        assert request(f.ports['admin'], 'GET', '/api/session', cookie=fresh)[0] == 401
        fresh, _ = login(f)
        viewer = dial(f, fresh)[1]; restarted = frame(viewer)
        assert restarted['epoch'] != initial['epoch'] and restarted['sections']['inFlight']['data']['recentlyFinished'] == []
        downstream = data_dial(f.ports['data'], token=secret)
        connected = until(viewer, lambda value: bool(value.get('sections', {}).get('inFlight', {}).get('data', {}).get('clients')))
        clients = connected['sections']['inFlight']['data']['clients']
        assert clients == [dict(keyID=key['id'], displayName=None, count=1, connectedAtUnixSeconds=clients[0]['connectedAtUnixSeconds'])]
        send(downstream, {'type': 'response.create', 'model': 'synthetic-text', 'input': 'stall'}, masked=True)
        until(viewer, lambda value: bool(value.get('sections', {}).get('inFlight', {}).get('data', {}).get('rows')))
        downstream.close()
        ended = until(viewer, lambda value: bool(value.get('sections', {}).get('inFlight', {}).get('data', {}).get('recentlyFinished')), seconds=20)
        assert not ended['sections']['inFlight']['data']['clients']
        assert ended['sections']['inFlight']['data']['recentlyFinished'][-1]['outcome'] in ('cancelled', 'failed', 'unknown')
        # Silent half-open viewer has a 15s ping + 10s pong deadline.
        half_cookie, _ = login(f)
        half = dial(f, half_cookie)[1]; frame(half); half.settimeout(28)
        heartbeat_start = time.monotonic()
        # Keep the normal viewer alive while the other ignores all ping frames.
        normal_stop = threading.Event()
        def normal_reader():
            while not normal_stop.is_set():
                try: frame(viewer)
                except (EOFError, OSError): return
        normal = threading.Thread(target=normal_reader, daemon=True); normal.start()
        try:
            while True:
                opcode, _ = receive(half)
                if opcode == 8: break
        except (EOFError, ConnectionResetError): pass
        measurements['missing_pong_close_seconds'] = round(time.monotonic() - heartbeat_start, 2)
        assert measurements['missing_pong_close_seconds'] <= 27
        assert normal.is_alive(), 'Healthy ping/pong viewer did not survive the silent peer'
        half.close(); normal_stop.set(); viewer.close(); normal.join(timeout=2)
        # SIGKILL cannot run connection cleanup. Restart must retire the session/epoch
        # without replaying data-plane work or inventing historical activity.
        fresh, _ = login(f); viewer = dial(f, fresh)[1]; before_kill = frame(viewer)
        with sqlite3.connect(f.root / 'state/core.sqlite') as db:
            attempts_before = db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0]
        connections_before = f.provider.connections
        f.process.kill(); f.process.wait(timeout=5)
        assert f.process.returncode == -9
        killed_output = f.process.stdout.read(131072)
        assert len(killed_output) < 131072
        assert all(secret.encode() not in killed_output for secret in f.secrets + [ADMIN])
        f.process.stdout.close(); viewer.close()
        f.process, f.ports = start(binary, f.config, f.root, admin_token_file=f.admin, web_directory=f.web_directory, admin_live=True)
        f.origin = f"http://127.0.0.1:{f.ports['admin']}"
        assert request(f.ports['admin'], 'GET', '/api/session', cookie=fresh)[0] == 401
        fresh, _ = login(f); viewer = dial(f, fresh)[1]; after_kill = frame(viewer)
        assert after_kill['epoch'] != before_kill['epoch']
        assert after_kill['sections']['inFlight']['data']['recentlyFinished'] == []
        assert after_kill['sections']['inFlight']['data']['clients'] == []
        with sqlite3.connect(f.root / 'state/core.sqlite') as db:
            assert db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0] == attempts_before
        assert f.provider.connections == connections_before
        measurements['sigkill_restart_without_replay'] = True
        viewer.close()
        # A real graceful stop closes the connection and returns within the shutdown budget.
        fresh, _ = login(f); viewer = dial(f, fresh)[1]; frame(viewer)
        stopped_at = time.monotonic(); f.process.terminate()
        try:
            terminal = until(viewer, lambda value: 'close' in value)
            assert terminal['close'] == 1001
        except (EOFError, ConnectionResetError):
            measurements['shutdown_close_frame_observed'] = False
        else: measurements['shutdown_close_frame_observed'] = True
        viewer.close(); f.process.wait(timeout=5)
        measurements['shutdown_seconds'] = round(time.monotonic() - stopped_at, 3)
    # Deployment switch disabled: handshake declines, ordinary reads continue.
    with running_admin(binary) as f:
        cookie, _ = login(f)
        assert dial(f, cookie)[0] != 101
        assert request(f.ports['admin'], 'GET', '/api/usage/in-flight', cookie=cookie)[0] == 200
    print('PASS: real admin upgrade authentication, 8/2 viewer limits, short committed activity, aggregate refresh, replacement/logout revocation, control-only frames, zero viewers and disabled fallback')
    print(json.dumps(measurements, sort_keys=True))


def verify_slow(probe):
    with tempfile.TemporaryDirectory(prefix='codexone-live-capacity-') as temporary:
        root = Path(temporary); (root / 'admin').write_text(ADMIN); (root / 'admin').chmod(0o600)
        process = subprocess.Popen([probe, '--admin-live-probe', str(root)], env={'PATH': os.defpath}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        sockets = []; readers = []; stop = threading.Event(); failures = []
        try:
            port = port_line(process, rb'ADMIN_PORT (\d+)')
            f = SimpleNamespace(ports={'admin': port}, origin=f'http://127.0.0.1:{port}', secrets=[])
            rss = lambda: int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(process.pid)]).strip()) * 1024
            before = rss(); peak = before
            cookie, _ = login(f)
            slow = dial(f, cookie, receive_buffer=1024)[1]; slow.settimeout(20); sockets.append(slow)
            def read(sock):
                try:
                    while not stop.is_set():
                        value = frame(sock)
                        if 'close' in value: raise AssertionError('Healthy viewer was closed')
                except (EOFError, OSError):
                    if not stop.is_set(): failures.append('healthy viewer disconnected')
                except BaseException as error: failures.append(type(error).__name__)
            for index in range(7):
                if index % 2 == 0: cookie, _ = login(f)
                current = dial(f, cookie)[1]; sockets.append(current)
                snapshot = frame(current)
                assert snapshot['kind'] == 'snapshot'
                assert len(snapshot['sections']['inFlight']['data']['rows']) == 200
                thread = threading.Thread(target=read, args=(current,), daemon=True); readers.append(thread); thread.start()
            # The slow peer never reads for 8s, well beyond the 5s socket write deadline.
            until_at = time.monotonic() + 8
            while time.monotonic() < until_at:
                peak = max(peak, rss()); time.sleep(.2)
                assert request(port, 'GET', '/api/session', cookie=cookie)[0] == 200
            try: terminal = until(slow, lambda value: 'close' in value, seconds=8)
            except (EOFError, ConnectionResetError): terminal = {'close': None}
            assert terminal['close'] in (1013, None)
            assert not failures, failures
            assert peak - before <= 48 * 1048576, (peak, before)
            print('PASS: actual non-reading TCP client is closed/forced closed under 200-row event storm; seven healthy viewers and HTTP survive')
            print(json.dumps({'rss_8_storm_added_bytes': peak - before, 'rss_baseline_bytes': before, 'rss_peak_bytes': peak, 'slow_close_frame': terminal['close'], 'max_snapshot_wire_bytes': snapshot['_wireBytes']}, sort_keys=True))
        finally:
            stop.set()
            for sock in sockets: sock.close()
            for thread in readers: thread.join(timeout=2)
            shutdown(process, root, [])


def verify_control_limit(binary):
    with running_admin(binary, admin_live=True) as fixture:
        cookie, _ = login(fixture)
        noisy = dial(fixture, cookie)[1]; frame(noisy)
        healthy = dial(fixture, cookie)[1]; frame(healthy)
        sent = 0
        try:
            for _ in range(65):
                send(noisy, b'synthetic-control', opcode=9, masked=True)
                sent += 1
        except (BrokenPipeError, ConnectionResetError):
            pass
        closed_with_frame = False
        try:
            result = until(noisy, lambda value: value.get('close') == 1008, seconds=5)
            closed_with_frame = result.get('close') == 1008
        except (EOFError, ConnectionResetError):
            pass
        finally:
            noisy.close()
        assert sent >= 64
        assert request(fixture.ports['admin'], 'GET', '/api/session', cookie=cookie)[0] == 200
        assert until(healthy, lambda value: value.get('kind') == 'update', seconds=6)['sequence'] > 1
        replacement = dial(fixture, cookie)[1]
        assert replacement is not None and frame(replacement)['kind'] == 'snapshot'
        replacement.close(); healthy.close()
        print('PASS: 65 control-frame burst closes only the noisy viewer; healthy updates, HTTP session and replacement slot survive')
        print(json.dumps({'control_frames_sent': sent, 'control_limit_close_frame': closed_with_frame}))


def serve(binary, web):
    with running_admin(binary, web_directory=web, admin_live=True) as f:
        _, secret = create(f.ports['admin']); f.secrets.append(secret)
        request(f.ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'synthetic'}, headers={'Authorization': 'Bearer ' + secret})
        print(json.dumps({'admin': f.ports['admin'], 'data': f.ports['data']}), flush=True)
        # The parent owns stdin and closes it to end the complete synthetic stack.
        input()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--probe', type=Path)
    parser.add_argument('--web', type=Path)
    args = parser.parse_args()
    if args.serve:
        serve(str(args.binary.resolve()), args.web.resolve())
    else:
        verify(str(args.binary.resolve()))
        verify_control_limit(str(args.binary.resolve()))
        if args.probe: verify_slow(str(args.probe.resolve()))
