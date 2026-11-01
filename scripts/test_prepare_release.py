#!/usr/bin/env python3
"""Synthetic release policy checks, including actual local Git tag ancestry."""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from prepare_release import changelog_section, validate_revision, version_from_tag

SCRIPT = Path(__file__).with_name('prepare_release.py').resolve()


class ReleasePolicyTests(unittest.TestCase):
    def test_tag_policy(self):
        for tag in ('v0.26.1', 'v0.26.12', 'v0.27.2-rc.1'):
            self.assertEqual(version_from_tag(tag), tag[1:])
        for tag in ('0.26.1', 'v1.26.1', 'v0.2026.1', 'v0.6.1', 'v0.26.0',
                    'v0.26.01', 'v0.26.1-rc.0', 'v0.26.1-rc.01', 'v0.26.1-beta.1',
                    'v0.26.1+build', 'v0.26.1\n', 'v0.26.1;echo bad'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                version_from_tag(tag)

    def test_notes_and_prerelease(self):
        text = ('# Changelog\n\n## 0.26.2-rc.1（2026-11-01）\n\n### 升级注意\n\n'
                'Synthetic RC. [Guide](docs/guide/backup-upgrade.md).\n\n### Changes\n\nRC only.\n\n'
                '## 0.26.1（2026-10-31）\n\n### 升级注意\n\nPrevious release.\n')
        notes = changelog_section(text, '0.26.2-rc.1')
        self.assertTrue(notes.startswith('### 升级注意\n'))
        self.assertIn('blob/v0.26.2-rc.1/docs/guide/backup-upgrade.md', notes)
        self.assertNotIn('Previous release', notes)
        with self.assertRaises(ValueError):
            changelog_section(text, '0.26.2')

    def test_missing_duplicate_unreleased_or_missing_upgrade(self):
        text = '## 0.26.1（未发布）\n\n### 升级注意\n\nSynthetic.\n'
        self.assertIn('Synthetic', changelog_section(text, '0.26.1', dry_run=True))
        for invalid, version in ((text, '0.26.1'), (text, '0.26.2'),
                                 (text + text, '0.26.1'),
                                 (text.replace('（未发布）', ' (Unreleased)'), '0.26.1'),
                                 ('## 0.26.1\n\n### Changes\n\nSynthetic.\n', '0.26.1'),
                                 ('## 0.26.1\n\n### 升级注意\n\n### Changes\n\nSynthetic.\n', '0.26.1'),
                                 ('## 0.26.1\n\n### 升级注意\n', '0.26.1')):
            with self.subTest(text=invalid), self.assertRaises(ValueError):
                changelog_section(invalid, version)

    def test_real_git_ancestry_and_tag_target(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            'GIT_AUTHOR_NAME': 'Synthetic', 'GIT_AUTHOR_EMAIL': 'synthetic@example.invalid',
            'GIT_COMMITTER_NAME': 'Synthetic', 'GIT_COMMITTER_EMAIL': 'synthetic@example.invalid',
        }):
            def git(*args):
                return subprocess.check_output(['git', '-C', temporary, *args], text=True, stderr=subprocess.DEVNULL).strip()
            git('init', '-b', 'main')
            git('commit', '--allow-empty', '-m', 'Synthetic base')
            git('tag', '-a', 'v0.26.1', '-m', 'Synthetic annotated tag')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            old = Path.cwd()
            try:
                os.chdir(temporary)
                self.assertEqual(validate_revision('v0.26.1', 'refs/remotes/origin/main'), git('rev-parse', 'HEAD'))
                git('checkout', '-b', 'synthetic-branch')
                git('commit', '--allow-empty', '-m', 'Synthetic off-main change')
                git('tag', 'v0.26.2-rc.1')
                with self.assertRaisesRegex(ValueError, 'main history'):
                    validate_revision('v0.26.2-rc.1', 'refs/remotes/origin/main')
                with self.assertRaisesRegex(ValueError, 'checked out commit'):
                    validate_revision('v0.26.1', 'refs/remotes/origin/main')
            finally:
                os.chdir(old)

    def test_cli_dry_run_and_prerelease_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(['git', '-C', temporary, *args], text=True, stderr=subprocess.DEVNULL).strip()
            git('init', '-b', 'main')
            git('-c', 'user.name=Synthetic', '-c', 'user.email=synthetic@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'Synthetic release')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            git('tag', 'v0.26.2-rc.1')
            changelog = root / 'CHANGELOG.md'
            changelog.write_text('## 0.26.2-rc.1（未发布）\n\n### 升级注意\n\nSynthetic RC.\n')
            command = [sys.executable, str(SCRIPT), '--output-dir', 'artifacts', '--github-output', 'outputs']
            dry = subprocess.run([*command, '--dry-run'], cwd=root, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertTrue(json.loads((root / 'artifacts/release.json').read_text())['dry_run'])
            release = subprocess.run([*command, '--tag', 'v0.26.2-rc.1'], cwd=root, capture_output=True)
            self.assertNotEqual(release.returncode, 0)
            changelog.write_text(changelog.read_text().replace('未发布', '2026-11-01'))
            (root / 'outputs').unlink()
            release = subprocess.run([*command, '--tag', 'v0.26.2-rc.1'], cwd=root, capture_output=True, text=True)
            self.assertEqual(release.returncode, 0, release.stderr)
            metadata = json.loads((root / 'artifacts/release.json').read_text())
            self.assertEqual(metadata, dict(version='0.26.2-rc.1', tag='v0.26.2-rc.1',
                                            revision=git('rev-parse', 'HEAD'), prerelease=True, dry_run=False))
            self.assertIn('prerelease=true\n', (root / 'outputs').read_text())
            self.assertTrue((root / 'artifacts/release-notes.md').read_text().startswith('### 升级注意'))


if __name__ == '__main__':
    unittest.main()
