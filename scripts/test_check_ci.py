#!/usr/bin/env python3
"""Regression checks for release coverage, failed gates and immutable artifact handoff."""

import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest

from check_ci import check_release, check_live_browser, workflow_jobs


ROOT = Path(__file__).resolve().parents[1]


class LiveBrowserWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/verify.yml').read_text()

    def test_real_stack_has_a_matching_binary_and_required_gate(self):
        check_live_browser(self.workflow)
        mutations = [
            ('needs: [changes, backend-build]', 'needs: changes'),
            ("CODEXONE_WEB_STUBS_ONLY: '0'", "CODEXONE_WEB_STUBS_ONLY: '1'"),
            ('npm run test:e2e -- admin-live-real --workers=1', 'true'),
            ("required.update({'backend-build', 'backend-swift-tests', 'backend-scripts', 'frontend-live'})", "required.add('backend-build')"),
            ('if [[ "$VERIFY_EVENT" == pull_request || "$VERIFY_EVENT" == push ]]; then', 'if true; then'),
            ('backend-build, backend-swift-tests, backend-scripts, frontend,', 'backend-build, backend-scripts, frontend,'),
            ('--testing-library swift-testing --no-parallel', '--testing-library swift-testing'),
            ('./scripts/verify.sh --backend-compile', './scripts/verify.sh --backend-build'),
        ]
        for before, after in mutations:
            with self.subTest(before=before), self.assertRaises(AssertionError):
                check_live_browser(self.workflow.replace(before, after))

    def test_actual_gate_requires_live_tests_for_backend_selection(self):
        gate = workflow_jobs(self.workflow)['verify']
        script = re.search(r"python3 - <<'PY'\n(.*?)^          PY$", gate, re.M | re.S)
        self.assertIsNotNone(script)
        code = textwrap.dedent(script[1])
        jobs = {'changes', 'docs', 'backend-build', 'backend-swift-tests', 'backend-scripts', 'frontend', 'frontend-live', 'devcontainer'}
        for backend, frontend, devcontainer in [(False, False, False), (True, False, False), (False, True, False), (True, True, True)]:
            required = {'changes', 'docs'}
            if backend: required.update({'backend-build', 'backend-swift-tests', 'backend-scripts', 'frontend-live'})
            if frontend: required.add('frontend')
            if devcontainer: required.add('devcontainer')
            needs = {job: {'result': 'success' if job in required else 'skipped'} for job in jobs}
            needs['changes']['outputs'] = {'backend': str(backend).lower(), 'frontend': str(frontend).lower(), 'devcontainer': str(devcontainer).lower()}
            def run(payload):
                return subprocess.run([sys.executable, '-c', code], capture_output=True,
                                      env={**os.environ, 'RESULTS': json.dumps(payload)}).returncode
            self.assertEqual(run(needs), 0)
            for job in required:
                for failed in ('failure', 'cancelled', 'skipped'):
                    with self.subTest(backend=backend, frontend=frontend, job=job, failed=failed):
                        payload = {name: dict(value) for name, value in needs.items()}
                        payload[job]['result'] = failed
                        self.assertNotEqual(run(payload), 0)


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
            ("--backend-scripts '${{ matrix.shard }}'", "--backend-scripts '${{ matrix.shard }}' --pr"),
            ('suite: [tls, installation, capacity]', 'suite: [tls, installation]'),
            ('scripts/verify_mixed_capacity.py --image', 'unchecked-capacity'),
            ('mixed-capacity-evidence', 'omitted-evidence'),
            ('--probe /binaries/ExecutionProbe --slow-only', '--skip-live-capacity'),
            ('ref: ${{ needs.build.outputs.revision }}', 'ref: main'),
            ('"$BINARIES_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('"$IMAGE_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('cmp binaries/codexone optimized-output/codexone', 'true'),
            ('--network none', ''),
            ('subject-digest: ${{ steps.push.outputs.digest }}', 'subject-digest: other'),
            ("if: github.event_name == 'push'", 'if: always()'),
            ('--target verification-export', '--target verification'),
            ('-release-buildkit-', '-swift-debug-'),
            ('--driver-opt image=moby/buildkit:', '--driver-opt image=unlocked:'),
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

    def build_script(self):
        build = workflow_jobs(self.release)['build']
        script = re.search(r'name: Build optimized executables and runtime once\n.*?'
                           r'        run: \|\n(.*?)(?=^      -)', build, re.M | re.S)
        self.assertIsNotNone(script)
        return textwrap.dedent(script[1])

    def run_build_with_fake_docker(self, root, use_cache, hit, fail=False):
        # Execute the workflow shell with a recording stub, never an image build.
        fake = root / 'docker'
        fake.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['DOCKER_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ['FAIL_BUILD'] == 'true' and sys.argv[1:3] == ['buildx', 'build']:
    sys.exit(1)
''')
        fake.chmod(0o755)
        log = root / 'calls.jsonl'
        # Match Actions' explicit bash shell (-e -o pipefail, without nounset).
        result = subprocess.run(['bash', '-eo', 'pipefail', '-c', self.build_script()], cwd=root,
                                capture_output=True, text=True, env={**os.environ,
                                    'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                    'DOCKER_CALLS': str(log), 'RUNNER_TEMP': str(root),
                                    'USE_BUILD_CACHE': use_cache, 'CACHE_HIT': hit,
                                    'FAIL_BUILD': str(fail).lower(),
                                    'VERSION': '0.26.1', 'REVISION': 'a' * 40})
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    def test_build_cache_modes_without_building_images(self):
        for use_cache, hit, restored in (('false', '', True), ('true', '', False),
                                         ('true', 'false', True), ('true', 'true', True)):
            with self.subTest(use_cache=use_cache, hit=hit, restored=restored), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                if restored:
                    for target in ('optimized', 'runtime'):
                        cache = root / 'release-buildkit' / target
                        cache.mkdir(parents=True)
                        (cache / 'index.json').write_text('{}')
                result, calls = self.run_build_with_fake_docker(root, use_cache, hit)
                self.assertEqual(result.returncode, 0, result.stderr)
                builds = [call for call in calls if call[:2] == ['buildx', 'build']]
                self.assertEqual(len(builds), 2)
                self.assertIn('verification-export', builds[0])
                self.assertIn('--load', builds[1])
                self.assertIn('codexone:candidate', builds[1])
                for build in builds:
                    self.assertEqual(build.count('--cache-from'), 2 if use_cache == 'true' and restored else 0)
                    self.assertEqual(build.count('--cache-to'), 1 if use_cache == 'true' and hit != 'true' else 0)
                    self.assertIn('BUILD_JOBS=2', build)
                    self.assertNotIn('verification', build)
                self.assertEqual(calls[-1], ['buildx', 'rm', '--force', 'codexone-release'])

    def test_build_failure_stops_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls = self.run_build_with_fake_docker(Path(temporary), 'false', '', fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sum(call[:2] == ['buildx', 'build'] for call in calls), 1)
            self.assertEqual(calls[-1], ['buildx', 'rm', '--force', 'codexone-release'])

    def test_image_archive_tampering_fails_at_every_handoff(self):
        for job in ('image-checks', 'verify', 'publish'):
            body = workflow_jobs(self.release)[job]
            line = next(line.strip() for line in body.splitlines()
                        if '"$IMAGE_ARCHIVE_SHA256" | sha256sum --check -' in line)
            with self.subTest(job=job), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / 'image/codexone-linux-amd64.tar.gz'
                archive.parent.mkdir()
                archive.write_bytes(b'Synthetic image archive')
                env = {**os.environ, 'IMAGE_ARCHIVE_SHA256': hashlib.sha256(archive.read_bytes()).hexdigest()}
                for tampered in (False, True):
                    if tampered:
                        archive.write_bytes(b'Synthetic tampered image archive')
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', line], cwd=root,
                                            capture_output=True, env=env)
                    self.assertEqual(result.returncode == 0, not tampered)


class AptFallbackTests(unittest.TestCase):
    def test_docker_package_steps_restore_sources_and_fail_closed(self):
        blocks = []
        for name in ('deploy/Dockerfile', 'deploy/tls-verification.Dockerfile', '.devcontainer/Dockerfile'):
            text = (ROOT / name).read_text()
            for block in re.findall(r'RUN src=/etc/apt/sources.list.d/ubuntu.sources.*?(?=\n(?:WORKDIR|COPY|USER|FROM|RUN|ARG|$))', text, re.S):
                script = block.replace('\\\n', ' ').removeprefix('RUN ')
                blocks.append(script.split('    && groupadd --gid')[0])
        self.assertEqual(len(blocks), 4)
        for script in blocks:
            for fail_all in (False, True):
                with self.subTest(fail_all=fail_all), tempfile.TemporaryDirectory(prefix='synthetic space ') as temporary:
                    root = Path(temporary)
                    source = root / 'sources'
                    original = 'http://archive.ubuntu.com/ubuntu\nhttp://security.ubuntu.com/ubuntu\n'
                    source.write_text(original)
                    (root / 'bin').mkdir()
                    (root / 'lists').mkdir()
                    apt = root / 'bin/apt-get'
                    apt.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_LOG"\ncase "$*" in *update*) if [ "$FAIL_ALL" = 1 ] || grep -q invalid.invalid "$TEST_SOURCES"; then exit 1; fi;; esac\nexit 0\n')
                    apt.chmod(0o755)
                    sed = root / 'bin/sed'
                    sed.write_text('#!/bin/sh\nif [ "$(uname -s)" = Darwin ] && [ "$1" = "-i" ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"\n')
                    sed.chmod(0o755)
                    command = (script.replace('/etc/apt/sources.list.d/ubuntu.sources', shlex.quote(str(source)))
                               .replace('/tmp/ubuntu.sources', shlex.quote(str(root / 'backup')))
                               .replace('/var/lib/apt/lists/*', shlex.quote(str(root / 'lists')) + '/*'))
                    env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.defpath,
                           'APT_MIRROR': 'http://invalid.invalid/ubuntu', 'TEST_SOURCES': str(source),
                           'TEST_LOG': str(root / 'calls'), 'FAIL_ALL': str(int(fail_all))}
                    result = subprocess.run(['sh', '-c', command], env=env, capture_output=True)
                    self.assertEqual(result.returncode == 0, not fail_all)
                    self.assertEqual(source.read_text(), original)
                    calls = (root / 'calls').read_text().splitlines()
                    self.assertEqual(sum('update' in call for call in calls), 2)
                    self.assertEqual(any('install' in call for call in calls), not fail_all)


if __name__ == '__main__':
    unittest.main()
