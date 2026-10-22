#!/usr/bin/env python3
"""Real private synthetic keyring/SQLite/CLI/SIGKILL maintenance; no provider calls."""
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

from verify_accounts import start, send
from verify_execution import line, dispose


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


def verify(binary, probe):
    with tempfile.TemporaryDirectory(prefix='codexone-key-maintenance-') as temporary:
        root = Path(temporary);root.chmod(0o700)
        state = root / 'state';state.mkdir(mode=0o700)
        database = state / 'core.sqlite'
        old, ring, reduced, wrong, admin = [root / name for name in ('old-key', 'ring', 'candidate', 'wrong-active', 'admin')]
        old.write_text('6a'*32);old.chmod(0o600)
        admin.write_text('synthetic-independent-administrator-' + 'a'*40);admin.chmod(0o600)
        private_json(ring, {'format':1, 'active':'7b'*32, 'decryptOnly':['6a'*32]})
        private_json(reduced, {'format':1, 'active':'7b'*32, 'decryptOnly':[]})
        private_json(wrong, {'format':1, 'active':'6a'*32, 'decryptOnly':['7b'*32]})
        process = start(probe, database, old)
        try:
            send(process, 'account-seed-maintenance', 'accounts_seeded')
            command(binary, state, admin, ring, '--reencrypt-credentials', root/'online', ok=False)
            assert not (root/'online').exists()
            send(process, 'close', 'closed');assert process.wait(timeout=5) == 0
        finally:dispose(process)
        # A real refresh writes the active key while 19 credentials retain their legacy version.
        process = start(probe, database, ring)
        try:
            send(process, 'account-refresh', 'refresh_started')
            send(process, 'account-commit', 'refresh_committed')
            send(process, 'account-refresh', 'refresh_started')
            send(process, 'close', 'closed');assert process.wait(timeout=5) == 0
        finally:dispose(process)
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
        # The package-only probe calls the same maintenance implementation and pauses after a durable page.
        bundle = root / 'pre-rotation'
        process = subprocess.Popen([probe, '--key-maintenance-probe', str(database), str(ring), str(bundle)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0, env={'PATH':os.defpath})
        try:
            assert line(process) == 'page_committed:8'
            process.kill();process.wait(timeout=5)
        finally:dispose(process)
        progress = command(binary, state, admin, ring, '--key-status')
        assert progress['checkpoint']['rewritten'] == 8 and not progress['checkpoint']['complete']
        assert len(progress['requiredCurrentKeyIDs']) == 2 and metadata(database) == original_metadata
        refused = command(binary, state, admin, ring, ok=False)
        assert b'Incomplete credential reencryption' in refused.stderr and b'LISTENING' not in refused.stdout
        command(binary, state, admin, wrong, '--resume-reencryption', ok=False)
        command(binary, state, admin, reduced, '--resume-reencryption', ok=False)
        command(binary, state, admin, ring, '--backup', root/'pending-backup', ok=False)
        assert not (root/'pending-backup').exists()
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
        complete = command(binary, state, admin, ring, '--resume-reencryption')
        assert complete['checkpoint']['complete'] and complete['checkpoint']['rewritten'] == 19
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
        process = start(probe, database, reduced)
        try:
            send(process, 'account-state', 'auth_uncertain:2:disabled')
            send(process, 'account-refresh', 'refresh_denied')
            send(process, 'close', 'closed');assert process.wait(timeout=5) == 0
        finally:dispose(process)
        for path in state.glob('core.sqlite*'):
            content = path.read_bytes()
            assert all(secret not in content for secret in [b'6a'*32,b'7b'*32,b'synthetic-access-1',b'synthetic-refresh-1',str(root).encode()])
        print('PASS: keyring legacy/mixed active writes, live lock, pre-backup, actual SIGKILL page/checkpoint and production startup refusal; CLI resume preserves context/refresh truth')
        print('PASS: read-only old backup dependencies/restore, candidate-key retirement inventory and drill checks, explicit old-copy disposal, new-key-only reopen and secret-free storage/output')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--probe',type=Path)
    args = parser.parse_args()
    try:verify(str(args.binary.resolve()),str((args.probe or args.binary.parent/'ExecutionProbe').resolve()))
    except Exception:
        print('FAIL: key maintenance verification; private diagnostics withheld',file=sys.stderr)
        raise SystemExit(1)
