#!/usr/bin/env python3
"""Copy the unique gateway test executable described by Cargo's JSON messages."""
import json
from pathlib import Path
import shutil
import sys


def export(messages, destination):
    matches = []
    for line in messages:
        record = json.loads(line)
        target = record.get('target', {})
        if (record['reason'] == 'compiler-artifact' and target.get('name') == 'codexone'
                and target.get('kind') == ['bin'] and record['profile']['test']
                and record['executable']):
            matches.append(Path(record['executable']))
    if len(matches) != 1 or not matches[0].is_file():
        raise SystemExit(f'Expected one codexone test executable, found {len(matches)}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(matches[0], destination)


if __name__ == '__main__':
    export(sys.stdin, Path(sys.argv[1]))
