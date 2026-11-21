#!/usr/bin/env python3
"""Private synthetic account encryption/refresh crash barriers; no provider or account calls."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.client import RemoteDisconnected
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import threading

from verify_admin import document, request
from verify_execution import line, dispose
from verify_managed_fixture import (
    ADMIN, AUTH, authorize, oauth_provider, prepare, refresh, start_gateway,
)
from verify_process import release
from verify_protocol import current_schema_version


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
                for path in root.glob('core.sqlite*'):
                    content = path.read_bytes()
                    assert all(secret not in content for secret in [b'synthetic-access-1', b'synthetic-refresh-1', b'synthetic-access-2', b'synthetic-refresh-2', ('5a' * 32).encode()])
                send(process, 'close', 'closed')
                assert process.wait(timeout=10) == 0
            finally:
                dispose(process)
        print('PASS: account SIGKILL ' + barrier + '; encrypted credentials, durable refresh state and conservative restart')


@contextmanager
def dispatched_refresh(port, provider, account):
    dispatched, disconnect = threading.Event(), threading.Event()
    with provider.guard:
        provider.control['refresh_gate'] = (dispatched, disconnect)
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(refresh, port, account)
        try:
            assert dispatched.wait(timeout=5), 'Synthetic refresh did not reach the provider'
            yield pending
        finally:
            disconnect.set()
            with provider.guard:
                provider.control.pop('refresh_gate')


def kill(process):
    process.kill()
    assert process.wait(timeout=5) == -signal.SIGKILL


def assert_disconnected(pending):
    try:
        pending.result(timeout=5)
    except (RemoteDisconnected, ConnectionResetError):
        return
    raise AssertionError('The killed gateway returned a refresh response')


def stored_account(database, account):
    with sqlite3.connect(database) as db:
        return db.execute('''
            SELECT authorization, credential_version, mode, sealed_credential, refresh_intent
              FROM accounts WHERE id=?
        ''', (account['id'],)).fetchone()


def verify_rust(binary, probe):
    schema = current_schema_version(binary)
    master = '5a' * 32
    for barrier, expected, version in (
        ('before_intent', 'ready', 1),
        ('after_intent', 'auth_uncertain', 1),
        ('after_commit', 'ready', 2),
    ):
        with tempfile.TemporaryDirectory(prefix='codexone-account-') as directory, oauth_provider(rust=True) as provider:
            root = Path(directory)
            database = prepare(root, master)
            process, port, _ = start_gateway(probe, root, provider, rust=True)
            try:
                account = authorize(port, provider)
                path = '/api/accounts/' + account['id']
                account = document(request(port, 'PUT', path, {'revision': account['revision'], 'mode': 'enabled'}, **AUTH))['account']
                original = stored_account(database, account)[3]
                if barrier == 'after_intent':
                    with dispatched_refresh(port, provider, account) as pending:
                        state, saved_version, mode, sealed, intent = stored_account(database, account)
                        assert (state, saved_version, mode, sealed) == ('refreshing', 1, 'enabled', original)
                        assert intent
                        kill(process)
                        assert_disconnected(pending)
                else:
                    if barrier == 'after_commit':
                        refreshed = document(refresh(port, account))['account']
                        assert (refreshed['authorization'], refreshed['credentialVersion']) == ('ready', 2)
                    kill(process)
            finally:
                release(process)

            recovered, port, output = start_gateway(probe, root, provider, rust=True)
            try:
                accounts = document(request(port, 'GET', '/api/accounts', **AUTH))['accounts']
                assert len(accounts) == 1 and accounts[0]['id'] == account['id']
                account = accounts[0]
                assert (account['authorization'], account['credentialVersion'], account['mode']) == (expected, version, 'enabled')
                state, saved_version, mode, sealed, intent = stored_account(database, account)
                assert (state, saved_version, mode) == (expected, version, 'enabled')
                assert (sealed == original) == (barrier != 'after_commit')
                assert bool(intent) == (barrier == 'after_intent')
                if barrier == 'after_intent':
                    assert refresh(port, account)[0] in (409, 503)
                assert provider.calls == (1 if barrier == 'before_intent' else 2)
                with sqlite3.connect(database) as db:
                    assert db.execute('PRAGMA user_version').fetchone() == (schema,)
                recovered.terminate()
                output += recovered.communicate(timeout=10)[0]
                assert recovered.returncode == 0
                secrets = [ADMIN, master, *provider.issued]
                assert all(secret.encode() not in output for secret in secrets)
                for path in database.parent.glob('core.sqlite*'):
                    data = path.read_bytes()
                    assert all(secret.encode() not in data for secret in secrets)
            finally:
                release(recovered)
        print(f'PASS: Rust managed account SIGKILL {barrier}; encrypted credentials and conservative restart')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--rust-probe', type=Path)
    args = parser.parse_args()
    if args.rust_probe:
        verify_rust(str(args.binary.resolve()), str(args.rust_probe.resolve()))
    else:
        verify(str(args.binary.resolve()))
