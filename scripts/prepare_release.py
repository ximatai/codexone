#!/usr/bin/env python3
"""Validate release inputs and extract notes without network or publishing access."""
import argparse
import json
from pathlib import Path
import re
import subprocess


VERSION = r'0\.[0-9]{2}\.[1-9][0-9]*(?:-rc\.[1-9][0-9]*)?'
TAG = re.compile(r'v(' + VERSION + r')', re.ASCII)


def version_from_tag(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError('Expected v0.YY.N or v0.YY.N-rc.N; sequence numbers start at 1')
    return match[1]


def changelog_section(text, version, dry_run=False):
    headings = list(re.finditer(r'^## (.+)$', text, re.MULTILINE))
    matches = [(index, heading) for index, heading in enumerate(headings)
               if re.match(re.escape(version) + r'(?=$|[ （(\[])', heading[1])]
    if len(matches) != 1:
        raise ValueError('CHANGELOG must contain exactly one matching version section')
    index, heading = matches[0]
    if not dry_run and re.search(r'未发布|unreleased', heading[1], re.IGNORECASE):
        raise ValueError('CHANGELOG version is still unreleased')
    end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
    notes = text[heading.end():end].strip()
    if not re.match(r'### 升级注意[^\S\n]*\n\s*[^#\s]', notes):
        raise ValueError('Release notes must start with a nonempty 升级注意 section')
    # Notes are rendered on GitHub, outside the source tree.
    notes = re.sub(r'(?<=\]\()((?:docs/|deploy/)[^\s)]+)(?=\))',
                   lambda match: f'https://github.com/ximatai/codexone/blob/v{version}/{match[0]}', notes)
    return notes + '\n'


def git(*arguments):
    return subprocess.check_output(['git', *arguments], text=True).strip()


def validate_revision(tag, main_ref):
    revision = git('rev-parse', 'HEAD^{commit}')
    if git('rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}') != revision:
        raise ValueError('Tag must point to the checked out commit')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', revision, main_ref], check=False).returncode != 0:
        raise ValueError('Tagged commit must be in main history')
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--main-ref', default='refs/remotes/origin/main')
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    text = args.changelog.read_text(encoding='utf-8')
    if args.tag:
        version = version_from_tag(args.tag)
        revision = validate_revision(args.tag, args.main_ref)
    elif args.dry_run:
        match = re.search(r'^## (' + VERSION + r')(?=$|[ （(\[])', text, re.MULTILINE)
        if not match:
            raise ValueError('No version section for dry-run')
        version, revision = match[1], git('rev-parse', 'HEAD^{commit}')
    else:
        raise ValueError('Publishing requires a tag')
    notes = changelog_section(text, version, args.dry_run)
    metadata = dict(version=version, tag='v' + version, revision=revision,
                    prerelease='-rc.' in version, dry_run=args.dry_run)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (args.output_dir / 'release-notes.md').write_text(notes)
    (args.output_dir / 'source-revision.txt').write_text(revision + '\n')
    if args.github_output:
        with args.github_output.open('a') as output:
            for name in ('version', 'tag', 'revision', 'prerelease'):
                output.write(f'{name}={str(metadata[name]).lower()}\n')
    print(f'PASS: {metadata["tag"]}; dry_run={args.dry_run}; CHANGELOG starts with 升级注意')


if __name__ == '__main__':
    main()
