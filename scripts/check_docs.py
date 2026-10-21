#!/usr/bin/env python3
"""Check project documentation structure without network or runtime dependencies."""
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'README.md', 'AGENTS.md', 'STATUS.md', 'HANDOFF.md', 'LICENSE',
    'docs/README.md', 'docs/governance.md', 'docs/requirements/product.md',
    'docs/specs/README.md', 'docs/architecture/ARCHITECTURE.md',
    'docs/decisions/README.md', 'docs/plans/roadmap.md',
    'docs/development/layout.md', 'docs/development/verification.md',
    'docs/architecture/ownership.md', 'docs/specs/execution-lifecycle.md',
    'docs/evidence/README.md',
)
# Logical/target directories evolve with implementation; validate stable
# documentation contracts, not the initial placeholder tree or a task name.
EXCLUDED_DIRECTORIES = {
    '.git', '.build', '.swiftpm', 'node_modules', 'dist', 'coverage',
    '.tmp', 'artifacts', '__pycache__', '.venv',
}


def markdown_files():
    for directory, subdirs, names in os.walk(ROOT):
        subdirs[:] = sorted(name for name in subdirs
                            if name not in EXCLUDED_DIRECTORIES)
        for name in sorted(names):
            if name.endswith('.md'):
                yield Path(directory) / name


errors = []
for name in REQUIRED:
    if not (ROOT / name).is_file():
        errors.append(f'Missing required file: {name}')
checked = 0
for path in markdown_files():
    rel = path.relative_to(ROOT)
    text = path.read_text(encoding='utf-8')
    if not text.strip() or not text.endswith('\n'):
        errors.append(f'Empty file or missing final newline: {rel}')
    checked += 1
    for link in re.findall(r'\]\(([^)]+)\)', text):
        target = link.strip().strip('<>')
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target):
            continue
        target = unquote(target.split('#', 1)[0])
        if not target:
            continue
        if target.startswith('/'):
            errors.append(f'Non-portable absolute file link in {rel}: {target}')
            continue
        resolved = (path.parent / target).resolve()
        try:
            resolved.relative_to(ROOT)
        except ValueError:
            errors.append(f'Link escapes repository in {rel}: {target}')
            continue
        if not resolved.exists():
            errors.append(f'Broken local file link in {rel}: {target}')

changes = ROOT / 'docs/changes'
if changes.exists():
    for change in changes.iterdir():
        if not change.is_dir():
            continue
        for name in ('proposal.md', 'tasks.md'):
            if not (change / name).is_file():
                errors.append(f'Missing change artifact: {change.name}/{name}')
        task_path = change / 'tasks.md'
        if task_path.exists() and not re.search(r'^- \[[ x]\] ', task_path.read_text(), re.M):
            errors.append(f'No task checkboxes: {change.name}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'PASS: {checked} Markdown documents, required entries, local links and change artifacts.')
print('Dependency/build directories excluded; logical source directories are not frozen.')
print('Scope: local file links only; no anchor, remote URL, code, protocol or runtime validation.')
