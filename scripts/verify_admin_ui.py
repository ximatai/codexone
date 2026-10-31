#!/usr/bin/env python3
"""Actual built management UI against a private synthetic gateway; screenshots exclude credentials."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from verify_admin import running_admin
from verify_keys import ADMIN
from browser_env import browser_env

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with running_admin(str(args.binary.resolve()), root / 'web/dist') as fixture:
    result = subprocess.run(['node', str(root / 'web/scripts/live-keys.mjs'), str(fixture.ports['admin']), str(fixture.ports['data']),
                             str(root / 'artifacts/key-management-ui'), str(fixture.root / 'state')],
                            input=json.dumps({'credential': ADMIN}).encode(), capture_output=True, timeout=90,
                            env=browser_env())
    output = result.stdout + result.stderr
    assert len(output) < 65536 and ADMIN.encode() not in output and str(fixture.root).encode() not in output
    assert re.search(rb'(?:co1_|as1_|ac1_)[A-Za-z0-9_-]{43}', output) is None
    print(output.decode(), end='')
    assert result.returncode == 0, 'Actual browser management verification failed; private inputs excluded from diagnostics'
