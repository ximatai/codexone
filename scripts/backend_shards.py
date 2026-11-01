#!/usr/bin/env python3
"""Validate shard ownership against the local --backend invocation list; list one shard."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re


def checked_groups():
    directory = Path(__file__).resolve().parent
    groups = json.loads((directory / 'backend_shards.json').read_text())
    source = (directory / 'verify.sh').read_text()
    commands = re.findall(r'^  run_check scripts/(verify_\w+\.py)(?: |$)', source, re.M)
    assigned = [name for group in groups for name in group]
    assert len(groups) == 4 and all(groups), 'Expected four nonempty shards'
    assert commands and len(commands) == len(set(commands)), 'Duplicate backend invocation'
    assert Counter(commands) == Counter(assigned), (
        f'Shard mismatch: missing={list((Counter(commands) - Counter(assigned)).elements())}, '
        f'extra/duplicate={list((Counter(assigned) - Counter(commands)).elements())}'
    )
    assert not re.search(r'^  python3 scripts/verify_.*\.py', source, re.M), (
        'Backend verification must go through run_check'
    )
    for name in assigned:
        assert (directory / name).is_file(), f'Missing script: {name}'
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--check', action='store_true')
    action.add_argument('--list', metavar='i/4')
    args = parser.parse_args()
    groups = checked_groups()
    if args.check:
        print(f'PASS: {sum(map(len, groups))} backend scripts belong to exactly one of {len(groups)} shards')
    elif args.list == 'all':
        print(' '.join('scripts/' + name for group in groups for name in group))
    else:
        if args.list not in [f'{i + 1}/{len(groups)}' for i in range(len(groups))]:
            parser.error(f'Expected shard 1/{len(groups)} through {len(groups)}/{len(groups)}')
        print(' '.join('scripts/' + name for name in groups[int(args.list.split('/')[0]) - 1]))


if __name__ == '__main__':
    main()
