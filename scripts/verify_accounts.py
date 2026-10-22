#!/usr/bin/env python3
"""Private synthetic account encryption/refresh crash barriers; no provider or account calls."""
import argparse
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from verify_execution import line, dispose


def start(binary, database, key):
    process = subprocess.Popen([binary, str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env={'PATH': os.defpath, 'CODEXONE_PROBE_KEY_FILE': str(key)}, bufsize=0)
    try:
        assert line(process) == 'ready'
        return process
    except BaseException:
        dispose(process)
        raise


def send(process, command, expected):
    process.stdin.write((command + '\n').encode())
    process.stdin.flush()
    assert line(process) == expected, 'Account probe returned an unexpected safe state'


def verify(binary):
    for barrier in ('before_intent', 'after_intent', 'after_commit'):
        with tempfile.TemporaryDirectory(prefix='codexone-account-') as temporary:
            root = Path(temporary)
            key = root / 'master'
            key.write_text('5a' * 32)
            key.chmod(0o600)
            database = root / 'core.sqlite'
            process = start(binary, database, key)
            try:
                send(process, 'account-create', 'account_created')
                send(process, 'account-enable', 'account_enabled')
                with sqlite3.connect(database) as db:
                    original = db.execute('SELECT sealed_credential FROM accounts').fetchone()[0]
                if barrier != 'before_intent':
                    send(process, 'account-refresh', 'refresh_started')
                if barrier == 'after_commit':
                    send(process, 'account-commit', 'refresh_committed')
                process.kill()
                process.wait(timeout=10)
            finally:
                dispose(process)
            process = start(binary, database, key)
            try:
                expected = {'before_intent': 'ready:1:enabled', 'after_intent': 'auth_uncertain:1:enabled', 'after_commit': 'ready:2:enabled'}[barrier]
                send(process, 'account-state', expected)
                if barrier == 'after_intent':
                    send(process, 'account-refresh', 'refresh_denied')
                with sqlite3.connect(database) as db:
                    row = db.execute('SELECT sealed_credential FROM accounts').fetchone()[0]
                    assert (row == original) == (barrier != 'after_commit')
                    assert db.execute('PRAGMA user_version').fetchone()[0] == 3
                for path in root.glob('core.sqlite*'):
                    content = path.read_bytes()
                    assert all(secret not in content for secret in [b'synthetic-access-1', b'synthetic-refresh-1', b'synthetic-access-2', b'synthetic-refresh-2', ('5a' * 32).encode()])
                send(process, 'close', 'closed')
                assert process.wait(timeout=10) == 0
            finally:
                dispose(process)
        print('PASS: account SIGKILL ' + barrier + '; encrypted credentials, durable refresh state and conservative restart')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    verify(str(parser.parse_args().binary.resolve()))
