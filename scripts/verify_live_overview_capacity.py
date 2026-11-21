#!/usr/bin/env python3
"""Check that one non-reading management viewer cannot stall other viewers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
import json
from pathlib import Path
import socket
import sqlite3
import threading
import time

from verify_admin import login, request, running_admin
from verify_admin_live import dial, frame
from verify_keys import create


INTENT_COUNT = 200
HEALTHY_VIEWERS = 7
RELEASE_SECONDS = 20


def seed_projection(database):
    now = int(time.time())
    metadata = json.dumps(dict(model='m' * 128, reasoningEffort='high', requestMetadataRecorded=True))
    # Seed after startup so recovery cannot convert projected intents to unknown.
    # The storm uses a separate Key and real requests through the gateway writer.
    with closing(sqlite3.connect(database)) as db, db:
        db.execute(
            'INSERT INTO managed_keys (id, digest, metadata_json) VALUES (?, ?, ?)',
            ('synthetic-parked-key', '0' * 64, json.dumps(dict(
                id='synthetic-parked-key', principal='synthetic-parked', enabled=False,
                displayName='键' * 64, createdAtUnixSeconds=now, revision=1,
                policy=dict(models=['m' * 128], limits=dict(tokens=None, active=None)),
            ))),
        )
        db.executemany(
            """INSERT INTO attempts
                (id, principal, key_id, namespace, identity, window_id, policy_version,
                 pricing_version, reserved, state, admission_json, created_at_epoch)
               VALUES (?, 'synthetic-parked', 'synthetic-parked-key', 'synthetic',
                       'synthetic-account', 'synthetic', '1', '1', 0, 'intent', ?, ?)""",
            [(f"{'a' * 253}{index:03}", metadata, now) for index in range(INTENT_COUNT)],
        )


def check_snapshot(snapshot):
    assert snapshot['kind'] == 'snapshot' and snapshot['sequence'] == 1
    activity = snapshot['sections']['inFlight']
    assert activity['freshness'] == 'fresh', activity['freshness']
    assert len(activity['data']['rows']) == INTENT_COUNT


def read_updates(sock, stop, stats):
    previous_sequence = 1
    while not stop.is_set():
        try:
            update = frame(sock)
        except (OSError, EOFError):
            if stop.is_set():
                return
            raise
        assert update.get('kind') == 'update', 'Healthy viewer closed or sent an unexpected frame'
        assert update['sequence'] == previous_sequence + 1
        previous_sequence = update['sequence']
        activity = update['sections'].get('inFlight', {}).get('data')
        if activity is not None and len(activity['rows']) == INTENT_COUNT:
            stats[0] += 1
            stats[1] += update['_wireBytes']


def generate_activity(port, secret, stop):
    completed = 0
    while not stop.is_set():
        status, _, _ = request(
            port, 'POST', '/v1/responses',
            {'model': 'synthetic-text', 'input': 'synthetic overview storm', 'stream': False},
            headers={'Authorization': 'Bearer ' + secret},
        )
        assert status == 200, ('synthetic storm request', status)
        completed += 1
        stop.wait(.15)
    return completed


def verify(binary):
    with running_admin(binary, admin_live=True) as fixture:
        admin, data = (fixture.ports[name] for name in ('admin', 'data'))
        _, secret = create(admin)
        fixture.secrets.append(secret)
        seed_projection(fixture.root / 'state/core.sqlite')
        stop = threading.Event()
        viewers = []
        readers = []
        statistics = [[0, 0] for _ in range(HEALTHY_VIEWERS)]
        maximum_snapshot = 0
        with ThreadPoolExecutor(max_workers=HEALTHY_VIEWERS + 1) as pool, ExitStack() as sockets:
            try:
                cookie, _ = login(fixture)
                started = time.monotonic()
                status, slow = dial(fixture, cookie, receive_buffer=1024)
                assert status == 101
                sockets.enter_context(slow)
                # Once upgraded, the slow peer never reads or sends anything.
                for index, stats in enumerate(statistics):
                    if index % 2 == 0:
                        cookie, _ = login(fixture)
                    status, healthy = dial(fixture, cookie)
                    assert status == 101
                    sockets.enter_context(healthy)
                    readers.append(healthy)
                    snapshot = frame(healthy)
                    check_snapshot(snapshot)
                    maximum_snapshot = max(maximum_snapshot, snapshot['_wireBytes'])
                    viewers.append(pool.submit(read_updates, healthy, stop, stats))
                replacement_cookie, _ = login(fixture)
                assert dial(fixture, replacement_cookie)[0] == 429, 'Eight viewer slots were not occupied'

                storm = pool.submit(generate_activity, data, secret, stop)
                replacement = None
                # The first missing-Pong deadline is 25 s after upgrading. The
                # slot must return earlier, while the original socket stays open.
                while time.monotonic() - started < RELEASE_SECONDS:
                    for observer in [storm, *viewers]:
                        if observer.done():
                            observer.result()
                    assert request(admin, 'GET', '/api/session', cookie=cookie)[0] == 200
                    status, replacement = dial(fixture, replacement_cookie)
                    released = time.monotonic() - started
                    if status == 101:
                        sockets.enter_context(replacement)
                        assert released < RELEASE_SECONDS, released
                        break
                    assert status == 429, ('replacement status', status)
                    time.sleep(.1)
                assert replacement is not None, 'Non-reading viewer retained its slot under write pressure'
                snapshot = frame(replacement)
                check_snapshot(snapshot)
                maximum_snapshot = max(maximum_snapshot, snapshot['_wireBytes'])
                assert all(count > 0 for count, _ in statistics), statistics
                before = [count for count, _ in statistics]
                deadline = time.monotonic() + 3
                while not all(stats[0] > count for stats, count in zip(statistics, before)):
                    for observer in [storm, *viewers]:
                        if observer.done():
                            observer.result()
                    assert time.monotonic() < deadline, 'Healthy viewers stopped receiving activity'
                    time.sleep(.05)
            finally:
                stop.set()
                # Unblock healthy reader threads before joining the executor.
                for sock in readers:
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        for observer in viewers:
            observer.result()
        completed = storm.result()
        assert completed > 0
        print('PASS: Rust live overview released a non-reading TCP viewer under activity; seven healthy viewers and HTTP survived')
        print(json.dumps({
            'slow_slot_released_seconds': round(released, 2), 'slow_peer_never_read': True,
            'max_snapshot_wire_bytes': maximum_snapshot, 'storm_responses': completed,
            'min_full_activity_updates': min(count for count, _ in statistics),
            'min_activity_update_bytes': min(size for _, size in statistics),
            'intents': INTENT_COUNT,
        }, sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    verify(str(parser.parse_args().binary.resolve(strict=True)))
