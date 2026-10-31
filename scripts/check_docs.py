#!/usr/bin/env python3
"""Check project documentation structure without network or runtime dependencies."""
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'README.md', 'README.en.md', 'AGENTS.md', 'STATUS.md', 'LICENSE',
    'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md',
    'CHANGELOG.md', 'THIRD_PARTY_NOTICES.md',
    'docs/README.md', 'docs/governance.md', 'docs/requirements/product.md',
    'docs/reference/specs/README.md', 'docs/architecture/ARCHITECTURE.md',
    'docs/architecture/decisions/README.md',
    'docs/development/layout.md', 'docs/development/verification.md',
    'docs/development/releasing.md', 'docs/architecture/ownership.md',
    'docs/reference/specs/execution-lifecycle.md',
    'docs/guide/README.md', 'docs/guide/linux-installation.md',
    'docs/guide/configuration.md', 'docs/guide/client-setup.md',
    'docs/guide/admin.md', 'docs/guide/backup-upgrade.md',
    'docs/guide/migration.md', 'docs/guide/faq.md',
    'docs/operations/README.md', 'docs/reference/README.md',
    'docs/reference/configuration.md', 'docs/reference/admin-api.md',
    'docs/reference/compatibility.md', 'docs/reference/provenance.md',
    'docs/assets/overview.png', 'docs/assets/keys.png',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/feature_request.yml',
    '.github/pull_request_template.md',
)
# Logical/target directories evolve with implementation; validate stable
# documentation contracts, not the initial placeholder tree or a task name.
EXCLUDED_DIRECTORIES = {
    '.git', '.build', '.swiftpm', 'node_modules', 'dist', 'coverage',
    '.tmp', 'artifacts', '__pycache__', '.venv', 'test-results', 'playwright-report',
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
for name in ('overview.png', 'keys.png'):
    asset = ROOT / 'docs/assets' / name
    if asset.is_file() and asset.stat().st_size > 400_000:
        errors.append(f'Documentation screenshot exceeds 400 KB: {name}')
checked = 0
for path in markdown_files():
    rel = path.relative_to(ROOT)
    text = path.read_text(encoding='utf-8')
    if not text.strip() or not text.endswith('\n'):
        errors.append(f'Empty file or missing final newline: {rel}')
    if rel.parts[0] == 'docs':
        lines = text.splitlines()
        if not lines or not re.fullmatch(r'# [^#].+', lines[0]):
            errors.append(f'Missing document title: {rel}')
        if len(lines) < 3 or not lines[2].strip() or lines[2].startswith(('#', '- ', '|', '```')):
            errors.append(f'Missing purpose paragraph after title: {rel}')
        if not re.search(r'^## 相关文档\n\n.+', text, re.M):
            errors.append(f'Missing related-document section: {rel}')
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
print(f'PASS: {checked} Markdown documents, required entries, document frames, local links, screenshot sizes and change artifacts.')
print('Dependency/build directories excluded; logical source directories are not frozen.')
print('Scope: local file links only; no anchor, remote URL, code, protocol or runtime validation.')
