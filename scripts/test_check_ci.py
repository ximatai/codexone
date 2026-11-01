#!/usr/bin/env python3
"""Regression checks for release coverage, failed gates and immutable artifact handoff."""

import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import textwrap
import unittest

from check_ci import check_release, workflow_jobs


ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.release = (ROOT / '.github/workflows/release.yml').read_text()
        self.dockerfile = (ROOT / 'deploy/Dockerfile').read_text()
        self.tls = (ROOT / 'deploy/tls-verification.Dockerfile').read_text()
        self.backend = (ROOT / 'scripts/verify.sh').read_text()

    def test_current_release(self):
        check_release(self.release, self.dockerfile, self.tls, self.backend)

    def test_reject_weakened_release(self):
        mutations = [
            ('needs: [build, backend-scripts, image-checks]', 'needs: [build, backend-scripts]'),
            ('needs: verify', 'needs: build'),
            ("if result != 'success':", "if result == 'failure':"),
            ('shard: [1/4, 2/4, 3/4, 4/4]', 'shard: [1/4, 2/4, 3/4]'),
            ('suite: [tls, installation]', 'suite: [installation]'),
            ('ref: ${{ needs.build.outputs.revision }}', 'ref: main'),
            ('"$BINARIES_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('"$IMAGE_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('cmp binaries/codexone optimized-output/codexone', 'true'),
            ('--network none', ''),
            ('subject-digest: ${{ steps.push.outputs.digest }}', 'subject-digest: other'),
            ("if: github.event_name == 'push'", 'if: always()'),
        ]
        for old, new in mutations:
            with self.subTest(old=old):
                self.assertIn(old, self.release)
                with self.assertRaises(AssertionError):
                    check_release(self.release.replace(old, new), self.dockerfile, self.tls, self.backend)

    def test_reject_omitted_original_verification(self):
        with self.assertRaisesRegex(AssertionError, 'retain every Dockerfile verification'):
            check_release(self.release, self.dockerfile, self.tls,
                          self.backend.replace('run_check scripts/verify_protocol.py', 'omitted'))

    def test_reject_different_tls_binary(self):
        with self.assertRaisesRegex(AssertionError, 'candidate binary'):
            check_release(self.release, self.dockerfile,
                          self.tls.replace('COPY --from=bundle /usr/local/bin/codexone /output/codexone', ''),
                          self.backend)

    def test_actual_gate_fails_closed(self):
        gate = workflow_jobs(self.release)['verify']
        script = re.search(r"python3 - <<'PY_GATE'\n(.*?)^          PY_GATE$", gate, re.M | re.S)
        self.assertIsNotNone(script)
        code = textwrap.dedent(script[1])
        jobs = ('build', 'backend-scripts', 'image-checks')
        for results in itertools.product(('success', 'failure', 'cancelled', 'skipped'), repeat=len(jobs)):
            needs = {job: {'result': result} for job, result in zip(jobs, results)}
            result = subprocess.run([sys.executable, '-c', code], capture_output=True,
                                    env={**os.environ, 'RESULTS': json.dumps(needs)})
            with self.subTest(results=results):
                self.assertEqual(result.returncode == 0, all(value == 'success' for value in results))


if __name__ == '__main__':
    unittest.main()
