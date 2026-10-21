#!/usr/bin/env python3
"""Check project documentation structure without network or runtime dependencies."""
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'README.md', 'AGENTS.md', 'STATUS.md', 'HANDOFF.md', 'LICENSE',
    'docs/README.md', 'docs/governance.md', 'docs/requirements/product.md',
    'docs/specs/README.md', 'docs/architecture/ARCHITECTURE.md',
    'docs/architecture/ARCHITECTURE-SYNTHESIS.md',
    'docs/decisions/README.md', 'docs/plans/roadmap.md',
    'docs/development/layout.md', 'docs/development/verification.md',
    'docs/changes/foundation-runtime/proposal.md',
    'docs/changes/foundation-runtime/tasks.md', 'docs/evidence/README.md',
)
DIRECTORIES = (
    'Sources/CodexOne', 'Sources/Domain', 'Sources/Application',
    'Sources/Protocol', 'Sources/Transport', 'Sources/Upstream',
    'Sources/Persistence', 'Sources/ControlPlane', 'Sources/Runtime',
    'Tests/Unit', 'Tests/Integration', 'Tests/Contract',
    'Tests/EndToEnd', 'Tests/Fixtures', 'web/src', 'web/tests', 'deploy',
)
errors = []
for name in REQUIRED:
    if not (ROOT / name).is_file():
        errors.append(f'Missing required file: {name}')
for name in DIRECTORIES:
    if not (ROOT / name).is_dir():
        errors.append(f'Missing logical directory: {name}')

checked = 0
snapshots = 0
for path in sorted(ROOT.rglob('*.md')):
    rel = path.relative_to(ROOT)
    if '.git' in rel.parts:
        continue
    # Original prototype documents reference its own source layout. Preserve
    # these snapshots verbatim; provenance explicitly identifies this boundary.
    historical = rel.as_posix().startswith('docs/evidence/prototype/')
    if historical and path.name != 'MANIFEST.md':
        snapshots += 1
        continue
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
        if not change.is_dir() or change.name in ('_template', 'archive'):
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
print(f'PASS: {checked} Markdown documents, required entries, logical directories and change artifacts.')
print(f'Historical prototype snapshots preserved: {snapshots}; their source-layout links are excluded.')
print('Scope: local file links only; no anchor, remote URL, code, protocol or runtime validation.')
