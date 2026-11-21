#!/usr/bin/env python3
"""Verify the account SPA with Chrome, a managed Rust gateway and synthetic OAuth."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from browser_env import browser_env
from verify_managed_fixture import ADMIN, oauth_provider, prepare, start_gateway
from verify_process import release


def verify(probe):
    root = Path(__file__).resolve().parents[1]
    master = '6b' * 32
    with (tempfile.TemporaryDirectory(prefix='codexone-account-ui-') as temporary,
          oauth_provider() as provider):
        work = Path(temporary)
        database = prepare(work, master, model='synth-text')
        process, port, output = start_gateway(probe, work, provider, web=root / 'web/dist')
        try:
            script = root / 'web/scripts/live-accounts.mjs'
            command = ['node', str(script), str(port), str(provider.server_port), str(work / 'browser')]
            result = subprocess.run(command, input=json.dumps({'credential': ADMIN}).encode(),
                                    capture_output=True, timeout=120, env=browser_env())
            browser_output = result.stdout + result.stderr
            assert len(browser_output) < 65536 and ADMIN.encode() not in browser_output and str(work).encode() not in browser_output
            assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}', browser_output) is None
            assert result.returncode == 0, 'Browser account verification failed; private inputs excluded: ' + browser_output.decode()
            print(browser_output.decode(), end='')
            process.terminate()
            output += process.communicate(timeout=10)[0]
            assert process.returncode == 0
            with provider.guard:
                issued = list(provider.issued)
                assert provider.calls == 5 and provider.quota_calls >= 3
            secrets = issued + [ADMIN, master, 'synthetic-private-quota-marker', 'SYNTH-CODE', 'synthetic-device-id-private']
            for file in database.parent.glob('core.sqlite*'):
                data = file.read_bytes()
                assert all(value.encode() not in data for value in secrets)
            assert len(output) < 65536 and str(work).encode() not in output
            assert all(value.encode() not in output for value in secrets)
        finally:
            release(process)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True, help='Rust gateway Cargo test executable')
    parser.add_argument('--rust', action='store_true', help='Compatibility flag for Rust verification callers')
    args = parser.parse_args()
    verify(str(args.binary.resolve()))
