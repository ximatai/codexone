#!/usr/bin/env python3
"""Verify offline keyring maintenance and backup retirement with synthetic credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

from verify_admin import document, request
from verify_managed_fixture import (
    AUTH, assert_disconnected, assert_refresh_denied, authorize, dispatched_refresh,
    kill, oauth_provider, prepare, refresh, start_gateway,
)
from verify_process import release


def private_json(path, value):
    path.write_text(json.dumps(value));path.chmod(0o600)


def command(binary, state, admin, key, *args, ok=True, identity=None):
    environment = {'PATH': os.defpath, 'CODEXONE_DATA_DIRECTORY': str(state),
             'CODEXONE_ADMIN_TOKEN_FILE': str(admin), 'CODEXONE_ACCOUNT_MASTER_KEY_FILE': str(key)}
    if identity:environment['CODEXONE_IDENTITY_CONFIG'] = str(identity)
    result = subprocess.run([binary, *map(str, args)], capture_output=True, timeout=30, env=environment)
    combined = result.stdout + result.stderr
    assert len(combined) < 32768 and str(state.parent).encode() not in combined
    assert all(secret not in combined for secret in [b'6a'*32, b'7b'*32, b'synthetic-access-1', b'synthetic-refresh-1'])
    assert (result.returncode == 0) == ok, 'Maintenance command returned an unexpected safe state'
    return json.loads(result.stdout) if ok else result


def metadata(database):
    with sqlite3.connect(database) as db:
        return db.execute('SELECT id,namespace,revision,credential_version,mode,authorization,refresh_intent,created_at_epoch FROM accounts ORDER BY id').fetchall()


def seed_accounts(binary, probe, provider, root, database, state, admin, ring):
    process, port, _ = start_gateway(probe, root, provider)
    try:
        legacy = authorize(port, provider, identity='synthetic-legacy-account')
        account = authorize(port, provider)
        assert legacy['id'] != account['id']
        command(binary, state, admin, ring, '--reencrypt-credentials', root/'online', ok=False)
        assert not (root/'online').exists()
        process.terminate()
        assert process.wait(timeout=5) == 0
    finally:
        release(process)
    process, port, _ = start_gateway(probe, root, provider, master=ring)
    try:
        account = document(refresh(port, account))['account']
        assert (account['authorization'], account['credentialVersion']) == ('ready', 2)
        with dispatched_refresh(port, provider, account) as pending:
            with sqlite3.connect(database) as db:
                state_row = db.execute('SELECT authorization, refresh_intent FROM accounts WHERE id=?', (account['id'],)).fetchone()
                assert state_row[0] == 'refreshing' and state_row[1]
            kill(process)
            assert_disconnected(pending)
    finally:
        release(process)
    return account['id']


def verify(binary, probe):
    with (tempfile.TemporaryDirectory(prefix='codexone-key-maintenance-') as temporary,
          oauth_provider() as provider):
        root = Path(temporary).resolve()
        database = prepare(root, '6a' * 32)
        state = database.parent
        ring, reduced, admin = [root / name for name in ('ring', 'candidate', 'admin')]
        private_json(ring, {'format':1, 'active':'7b'*32, 'decryptOnly':['6a'*32]})
        private_json(reduced, {'format':1, 'active':'7b'*32, 'decryptOnly':[]})
        interrupted_id = seed_accounts(binary, probe, provider, root, database, state, admin, ring)
        original_metadata = metadata(database)
        before = command(binary, state, admin, ring, '--key-status')
        assert len(before['requiredCurrentKeyIDs']) == 2 and before.get('checkpoint') is None
        # Every maintenance path must reject reuse of active, decrypt-only, or the whole compact keyring.
        identity = root/'identity.json'
        for number, secret in enumerate(('7b'*32,'6a'*32,json.dumps(json.loads(ring.read_text()),separators=(',',':')))):
            if number == 2:private_json(ring,json.loads(secret));ring.write_text(secret)
            private_json(identity, {'principal':'synthetic','keyID':'synthetic','namespace':'synthetic',
                'identity':'synthetic','reservedMicros':0,'keySHA256':hashlib.sha256(secret.encode()).hexdigest(),
                'models':[{'id':'synthetic-text','inputMicrosPerMillion':0,'outputMicrosPerMillion':0,
                           'catalog':{'baseInstructions':'Explicit synthetic guidance'}}],
                'upstreamBaseURL':'http://127.0.0.1:9/v1'})
            destination = root/('reuse-refused-'+str(number))
            command(binary,state,admin,ring,'--reencrypt-credentials',destination,ok=False,identity=identity)
            assert not destination.exists() and metadata(database) == original_metadata
            assert command(binary,state,admin,ring,'--key-status').get('checkpoint') is None
        command(binary, state, admin, reduced, '--reencrypt-credentials', root/'missing-key', ok=False)
        assert not (root/'missing-key').exists()
        bundle = root / 'pre-rotation'
        # The maintenance crate exercises interruption at its private post-commit boundary.
        complete = command(binary, state, admin, ring, '--reencrypt-credentials', bundle)
        for path in bundle.iterdir():path.chmod(0o400)
        bundle.chmod(0o500)
        manifest = command(binary, state, admin, ring, '--verify-backup', bundle)
        assert manifest['requiredKeyIDs'] == before['requiredCurrentKeyIDs']
        command(binary, state, admin, reduced, '--verify-backup', bundle, ok=False)
        old_drill = root / 'old-drill'
        restored = command(binary, old_drill, admin, ring, '--restore', bundle)
        assert restored['state'] == 'restored_unreconciled'
        bundle.chmod(0o700)
        for path in bundle.iterdir():path.chmod(0o600)
        assert complete['checkpoint']['complete'] and complete['checkpoint']['rewritten'] == 1
        assert complete['requiredCurrentKeyIDs'] == [complete['activeKeyID']]
        assert command(binary, state, admin, ring, '--resume-reencryption') == complete
        assert metadata(database) == original_metadata
        fresh = root / 'post-rotation'
        fresh_manifest = command(binary, state, admin, reduced, '--backup', fresh)
        assert fresh_manifest['requiredKeyIDs'] == [complete['activeKeyID']]
        new_drill = root / 'new-drill'
        command(binary, new_drill, admin, reduced, '--restore', fresh)
        inventory = root / 'inventory.json'
        base = {'format':1, 'inventoryComplete':True, 'auditReference':'synthetic-retirement-1',
                'legacyDatabases':[], 'retainedBackups':[str(bundle),str(fresh)], 'restoreDrills':[str(old_drill),str(new_drill)]}
        private_json(inventory, {**base, 'inventoryComplete':False})
        command(binary, state, admin, ring, '--check-key-retirement', inventory, ok=False)
        private_json(inventory, {**base, 'restoreDrills':[]})
        command(binary, state, admin, ring, '--check-key-retirement', inventory, ok=False)
        private_json(inventory, base)
        command(binary, state, admin, reduced, '--check-key-retirement', inventory, ok=False)
        evidence = command(binary, state, admin, ring, '--check-key-retirement', inventory)
        assert evidence['requiredBackupKeyIDs'] == before['requiredCurrentKeyIDs']
        assert set(evidence['verifiedBackupIDs']) == {manifest['id'],fresh_manifest['id']}
        # Explicitly discard only these private synthetic old copies, then attest the complete retained inventory.
        shutil.rmtree(bundle);shutil.rmtree(old_drill)
        private_json(inventory, {**base, 'auditReference':'synthetic-retirement-2',
                                'retainedBackups':[str(fresh)], 'restoreDrills':[str(new_drill)]})
        evidence = command(binary, state, admin, reduced, '--check-key-retirement', inventory)
        assert evidence['requiredBackupKeyIDs'] == [complete['activeKeyID']]
        process, port, _ = start_gateway(probe, root, provider, master=reduced)
        try:
            accounts = document(request(port, 'GET', '/api/accounts', **AUTH))['accounts']
            account, = [account for account in accounts if account['id'] == interrupted_id]
            assert (account['authorization'], account['credentialVersion'], account['mode']) == ('auth_uncertain', 2, 'disabled')
            calls = provider.calls
            assert_refresh_denied(port, account)
            assert provider.calls == calls
            process.terminate()
            assert process.wait(timeout=5) == 0
        finally:
            release(process)
        secrets = [b'6a' * 32, b'7b' * 32, str(root).encode(), *(value.encode() for value in provider.issued)]
        for path in state.glob('core.sqlite*'):
            content = path.read_bytes()
            assert all(secret not in content for secret in secrets)
        print('PASS: keyring legacy/mixed active writes, live lock, pre-backup and CLI resume preserve context and refresh state')
        print('PASS: read-only old backup dependencies/restore, candidate-key retirement inventory and drill checks, explicit old-copy disposal, new-key-only reopen and secret-free storage/output')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--rust-probe', type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(str(args.binary.resolve()), str(args.rust_probe.resolve()))
    except Exception:
        print('FAIL: key maintenance verification; private diagnostics withheld',file=sys.stderr)
        raise SystemExit(1)
