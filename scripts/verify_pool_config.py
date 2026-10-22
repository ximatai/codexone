#!/usr/bin/env python3
"""Private production pool assembly without an account or any upstream request."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from verify_admin import request
from verify_process import assert_released, release
from verify_protocol import start


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    binary = str(parser.parse_args().binary.resolve())
    with tempfile.TemporaryDirectory(prefix='codexone-pool-') as temporary:
        root = Path(temporary)
        admin = root / 'admin'
        master = root / 'master'
        config = root / 'pool.json'
        admin.write_text('synthetic-private-admin-key-00001')
        master.write_text('6a' * 32)
        document = dict(models=[dict(id='synthetic-text', inputMicrosPerMillion=1, outputMicrosPerMillion=1)], reservedMicros=1)
        config.write_text(json.dumps(document))
        for file in [admin, master, config]:
            file.chmod(0o600)
        env = dict(PATH=os.defpath, CODEXONE_DATA_DIRECTORY=str(root / 'state'),
                   CODEXONE_ADMIN_TOKEN_FILE=str(admin), CODEXONE_ACCOUNT_MASTER_KEY_FILE=str(master),
                   CODEXONE_ACCOUNT_POOL_CONFIG=str(config), CODEXONE_DATA_PORT='0', CODEXONE_ADMIN_PORT='0')
        checked = subprocess.run([binary, '--check-config'], env=env, capture_output=True, timeout=15)
        assert checked.returncode == 0 and not (root / 'state').exists()
        for field in ['upstreamBaseURL', 'upstreamTransport', 'headers']:
            config.write_text(json.dumps({**document, field: 'synthetic-unsupported-override'}))
            rejected = subprocess.run([binary, '--check-config'], env=env, capture_output=True, timeout=15)
            assert rejected.returncode != 0 and b'synthetic-unsupported-override' not in rejected.stderr
            assert str(root).encode() not in rejected.stderr and not (root / 'state').exists()
        config.write_text(json.dumps(document))
        config.chmod(0o644)
        rejected = subprocess.run([binary, '--check-config'], env=env, capture_output=True, timeout=15)
        assert rejected.returncode != 0 and not (root / 'state').exists()
        config.chmod(0o600)
        for _ in range(2):
            process, ports = start(binary, None, root, admin_token_file=admin,
                                   account_master_key_file=master, account_pool_config=config)
            try:
                for port in ports.values():
                    assert request(port, 'GET', '/health/live')[0] == 200
                    status, _, body = request(port, 'GET', '/health/ready')
                    assert status == 503
                    assert not next(check['ready'] for check in json.loads(body)['checks'] if check['name'] == 'upstream_accounts')
                assert request(ports['data'], 'POST', '/v1/responses', {'model': 'synthetic-text', 'input': 'text'})[0] == 401
                status, _, body = request(ports['admin'], 'GET', '/api/accounts', headers={'Authorization': 'Bearer ' + admin.read_text()})
                assert status == 200 and b'namespace' not in body
                for marker in [admin.read_bytes(), master.read_bytes(), str(root).encode()]:
                    assert marker not in body
            finally:
                release(process)
            assert process.returncode == 0
            for port in ports.values():
                assert_released(port)
    print('PASS: private pool config rejects overrides/insecure files without storage; production empty-pool readiness stays unavailable; managed auth and shutdown/reopen work without upstream calls')


if __name__ == '__main__':
    main()
