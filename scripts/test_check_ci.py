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

from check_ci import check_live_browser, check_release, check_rust, workflow_jobs


ROOT = Path(__file__).resolve().parents[1]


class VerifyWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/verify.yml').read_text()

    def test_real_stack_has_a_matching_binary_and_required_gate(self):
        check_live_browser(self.workflow)
        mutations = [
            ('needs: [changes, backend-build, backend-rust-build]', 'needs: changes'),
            ("CODEXONE_WEB_STUBS_ONLY: '0'", "CODEXONE_WEB_STUBS_ONLY: '1'"),
            ('npm run test:e2e -- admin-live-real --workers=1', 'true'),
            ('CODEXONE_WEB_TEST_BINARY: ../.build/live/codexone', 'CODEXONE_WEB_TEST_BINARY: ../.build/debug/codexone'),
            ("'[\"swift\",\"rust\"]'", "'[\"swift\"]'"),
            ('if [[ "$VERIFY_EVENT" == pull_request || "$VERIFY_EVENT" == push ]]; then', 'if true; then'),
            ('backend-swift-tests, backend-scripts, backend-rust,', 'backend-scripts, backend-rust,'),
            ('--testing-library swift-testing --no-parallel', '--testing-library swift-testing'),
            ('./scripts/verify.sh --backend-compile', './scripts/verify.sh --backend-build'),
        ]
        for before, after in mutations:
            with self.subTest(before=before), self.assertRaises(AssertionError):
                check_live_browser(self.workflow.replace(before, after))

    def test_rust_protocol_jobs_require_the_optimized_gateway_and_all_shards(self):
        dockerfile = (ROOT / 'deploy/Dockerfile').read_text()
        check_rust(self.workflow, dockerfile)
        mutations = [
            ('./scripts/verify_rust.sh --crate-tests', 'true'),
            ('-C rust/gateway/target/release codexone', '-C rust/gateway/target/debug codexone'),
            ('needs: [changes, backend-rust-build]', 'needs: changes'),
            ('shard: [1/4, 2/4, 3/4, 4/4]', 'shard: [1/4, 2/4, 3/4]'),
            ('"${args[@]}" --rust', '"${args[@]}"'),
            ('scripts/rust_compat/compare.py', 'unchecked'),
        ]
        for before, after in mutations:
            with self.subTest(before=before), self.assertRaises(AssertionError):
                check_rust(self.workflow.replace(before, after), dockerfile)

    def test_actual_gate_requires_selected_jobs(self):
        workflow = workflow_jobs(self.workflow)
        gate = workflow['verify']
        script = re.search(r"python3 - <<'PY'\n(.*?)^          PY$", gate, re.M | re.S)
        self.assertIsNotNone(script)
        code = textwrap.dedent(script[1])
        jobs = set(workflow) - {'verify'}
        selections = [(), ('backend',), ('rust',), ('frontend',), ('rust', 'frontend'),
                      ('backend', 'rust'), ('devcontainer',), ('backend', 'rust', 'frontend', 'devcontainer')]
        for selected in selections:
            required = {'changes', 'docs'}
            if 'backend' in selected:
                required.update({'backend-build', 'backend-swift-tests', 'backend-scripts', 'frontend-live'})
            if 'rust' in selected:
                required.update({'backend-rust', 'backend-rust-build', 'backend-rust-scripts', 'frontend-live'})
            if {'backend', 'rust'} <= set(selected):
                required.add('backend-parity')
            if 'frontend' in selected:
                required.update({'backend-rust-build', 'frontend-live'})
            required.update({'frontend', 'devcontainer'}.intersection(selected))
            needs = {job: {'result': 'success' if job in required else 'skipped'} for job in jobs}
            needs['changes']['outputs'] = {name: str(name in selected).lower()
                                          for name in ('backend', 'rust', 'frontend', 'devcontainer')}
            def run(payload):
                return subprocess.run([sys.executable, '-c', code], capture_output=True,
                                      env={**os.environ, 'RESULTS': json.dumps(payload)}).returncode
            self.assertEqual(run(needs), 0)
            for job in required:
                with self.subTest(selected=selected, missing=job):
                    self.assertNotEqual(run({name: value for name, value in needs.items() if name != job}), 0)
                for failed in ('failure', 'cancelled', 'skipped'):
                    with self.subTest(selected=selected, job=job, failed=failed):
                        payload = {name: dict(value) for name, value in needs.items()}
                        payload[job]['result'] = failed
                        self.assertNotEqual(run(payload), 0)
            for selection in needs['changes']['outputs']:
                with self.subTest(selected=selected, invalid=selection):
                    outputs = {**needs['changes']['outputs'], selection: ''}
                    self.assertNotEqual(run({**needs, 'changes': {'result': 'success', 'outputs': outputs}}), 0)


class ChangedPathsTests(unittest.TestCase):
    def test_selects_checks_for_code_shared_inputs_and_docs(self):
        cases = [
            (['rust/gateway/README.md'], set()),
            (['rust/gateway/Cargo.lock', 'rust/wire/src/With\nNewline.rs'], {'rust'}),
            (['scripts/verify_rust.sh'], {'rust'}),
            (['scripts/verify.sh'], {'backend', 'rust', 'frontend', 'devcontainer'}),
            (['.github/workflows/verify.yml'], {'backend', 'rust', 'frontend', 'devcontainer'}),
            (['deploy/Dockerfile'], {'backend', 'rust'}),
            (['scripts/verify_websocket.py'], {'backend', 'rust'}),
            (['scripts/verify_admin_live.py'], {'backend', 'rust'}),
            (['scripts/verify_text_contract.py'], {'backend', 'rust'}),
            (['scripts/rust_compat/compare.py'], {'backend', 'rust'}),
            (['scripts/verify_migration_cutback.py'], {'backend', 'rust'}),
            (['rust/storage/src/migration.rs'], {'backend', 'rust'}),
            (['rust/maintenance/src/lib.rs'], {'backend', 'rust'}),
            (['rust/gateway/src/online_backup.rs'], {'backend', 'rust'}),
            (['rust/gateway/src/main.rs'], {'backend', 'rust'}),
            (['Sources/CodexOne/CodexOneMain.swift'], {'backend', 'rust'}),
            (['Sources/CodexOneAdapters/Persistence/SQLiteSnapshotMaintenance.swift'], {'backend', 'rust'}),
            (['Tests/CodexOneAdaptersTests/Fixtures/system-status.json'], {'backend', 'rust'}),
            (['Sources/CodexOneCore/Domain/Identity/AccountCredential.swift'], {'backend'}),
            (['web/src/App.tsx'], {'frontend'}),
            (['Sources/CodexOneCore/Domain/Identity/AccountCredential.swift', 'web/src/App.tsx'], {'backend', 'frontend'}),
            (['.devcontainer/Dockerfile'], {'devcontainer'}),
            (['unknown-root-file'], {'backend', 'rust', 'frontend'}),
            ([f'docs/{index:03}.md' for index in range(320)] + ['rust/gateway/Cargo.toml'], {'rust'}),
        ]
        for paths, expected in cases:
            with self.subTest(last_path=paths[-1]):
                result = subprocess.run(['bash', 'scripts/ci_changes.sh'], cwd=ROOT, check=True,
                                        input='\0'.join(paths) + '\0', capture_output=True, text=True)
                self.assertEqual({line.removesuffix('=true') for line in result.stdout.splitlines()
                                  if line.endswith('=true')}, expected)

    def test_preserves_swift_coverage_when_adding_rust_shards(self):
        swift_only = {
            'verify_accounts.py', 'verify_admin_round2.py', 'verify_execution.py',
            'verify_key_maintenance.py', 'verify_storage_pressure.py', 'verify_upstream_proxy.py',
            'verify_gateway_diagnostics.py', 'verify_key_export.py', 'verify_model_profiles_import.py',
        }
        for mode in ([], ['--pr']):
            def shard_suites(*flags):
                suites = []
                for shard in ('1/4', '2/4', '3/4', '4/4'):
                    cmd = [sys.executable, 'scripts/backend_shards.py', '--list', shard, *mode, *flags]
                    batch = subprocess.check_output(cmd, cwd=ROOT, text=True).split()
                    self.assertTrue(batch)
                    suites.extend(Path(name).name for name in batch)
                self.assertEqual(len(suites), len(set(suites)))
                return set(suites)

            swift, rust = shard_suites(), shard_suites('--rust')
            self.assertLessEqual(swift_only, swift)
            self.assertEqual(rust, swift - swift_only)

    def test_quick_rust_shards_call_the_selected_binary_and_protocol_modes(self):
        # Run the shell dispatcher without starting any gateway or provider.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'calls'
            binary = root / 'codexone'
            binary.touch(mode=0o755)
            python = root / 'python3'
            python.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
if sys.argv[1] == 'scripts/backend_shards.py':
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
with open(os.environ['CALL_LOG'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
''')
            python.chmod(0o755)
            env = {**os.environ, 'CODEXONE_BACKEND_BIN_DIR': str(root),
                   'PATH': str(root) + os.pathsep + os.environ['PATH'], 'CALL_LOG': str(log)}
            cmd = ['bash', 'scripts/verify.sh', '--backend-scripts', 'all', '--pr', '--rust']
            subprocess.run(cmd, cwd=ROOT, env=env, check=True, capture_output=True)
            recorded = log.read_text().splitlines()
            calls = {path: args for path, *args in map(json.loads, recorded)}
            expected = subprocess.check_output(
                [sys.executable, 'scripts/backend_shards.py', '--list', 'all', '--pr', '--rust'],
                cwd=ROOT, text=True).split()
            self.assertEqual(set(calls), set(expected))
            self.assertEqual(len(recorded), len(expected))
            for args in calls.values():
                self.assertEqual(args[:2], ['--binary', str(binary)])
            self.assertEqual(calls['scripts/verify_client_protocol.py'][2:], ['--expect-provider-eof'])
            self.assertEqual(calls['scripts/verify_snapshot_restore.py'][2:], ['--linked-paths'])
            self.assertEqual(calls['scripts/verify_admin_live.py'][2:], ['--backend', 'rust'])
            self.assertEqual({Path(path).name for path, args in calls.items() if '--smoke' in args}, {
                'verify_images.py', 'verify_response_finish.py', 'verify_text_contract.py',
                'verify_upload_deadline.py', 'verify_upstream_ws_body_limit.py', 'verify_upstream_zstd.py',
            })


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
            ("--backend-scripts '${{ matrix.shard }}' --rust-release", "--backend-scripts '${{ matrix.shard }}' --pr"),
            ('suite: [tls, installation, capacity]', 'suite: [tls, installation]'),
            ('scripts/verify_mixed_capacity.py --image', 'unchecked-capacity'),
            ('mixed-capacity-evidence', 'omitted-evidence'),
            ('--probe /binaries/ExecutionProbe --slow-only', '--skip-live-capacity'),
            ('ref: ${{ needs.build.outputs.revision }}', 'ref: main'),
            ('"$BINARIES_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('"$IMAGE_ARCHIVE_SHA256" | sha256sum --check -', 'unchecked'),
            ('cmp binaries/codexone optimized-output/codexone', 'true'),
            ('-f deploy/Dockerfile -t codexone:candidate', '--build-arg CODEXONE_BACKEND=swift -f deploy/Dockerfile -t codexone:candidate'),
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

    def test_reject_swift_as_the_docker_default(self):
        with self.assertRaisesRegex(AssertionError, 'must default to Rust'):
            check_release(self.release, self.dockerfile.replace('ARG CODEXONE_BACKEND=rust',
                                                              'ARG CODEXONE_BACKEND=swift'),
                          self.tls, self.backend)

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
                with self.subTest(fail_all=fail_all), tempfile.TemporaryDirectory(prefix="synthetic ' $() ") as temporary:
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
