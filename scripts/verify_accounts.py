#!/usr/bin/env python3
"""Private synthetic account encryption/refresh crash barriers; synthetic loopback only."""
import argparse
from pathlib import Path
import sqlite3
import tempfile

from verify_admin import document, request
from verify_managed_fixture import (
    ADMIN, AUTH, assert_disconnected, assert_refresh_denied, authorize, dispatched_refresh,
    kill, oauth_provider, prepare, refresh, start_gateway,
)
from verify_process import release
from verify_protocol import current_schema_version


def stored_account(database, account):
    with sqlite3.connect(database) as db:
        return db.execute('''
            SELECT authorization, credential_version, mode, sealed_credential, refresh_intent
              FROM accounts WHERE id=?
        ''', (account['id'],)).fetchone()


def verify(binary, probe):
    schema = current_schema_version(binary)
    master = '5a' * 32
    for barrier, expected, version in (
        ('before_intent', 'ready', 1),
        ('after_intent', 'auth_uncertain', 1),
        ('after_commit', 'ready', 2),
    ):
        with tempfile.TemporaryDirectory(prefix='codexone-account-') as directory, oauth_provider() as provider:
            root = Path(directory)
            database = prepare(root, master)
            process, port, _ = start_gateway(probe, root, provider)
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

            recovered, port, output = start_gateway(probe, root, provider)
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
                    assert_refresh_denied(port, account)
                assert provider.calls == (1 if barrier == 'before_intent' else 2)
                with sqlite3.connect(database) as db:
                    assert db.execute('PRAGMA user_version').fetchone() == (schema,)
                    actions = db.execute(
                        "SELECT action FROM account_events WHERE account_id=? AND action LIKE 'refresh_%' ORDER BY revision",
                        (account['id'],),
                    ).fetchall()
                    expected_actions = {
                        'before_intent': [],
                        'after_intent': [('refresh_begin',), ('refresh_restart_uncertain',)],
                        'after_commit': [('refresh_begin',), ('refresh_commit',)],
                    }
                    assert actions == expected_actions[barrier]
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
    parser.add_argument('--rust-probe', type=Path, required=True)
    args = parser.parse_args()
    verify(str(args.binary.resolve()), str(args.rust_probe.resolve()))
