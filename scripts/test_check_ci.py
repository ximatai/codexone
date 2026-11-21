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
            ('needs: [changes, backend-rust-build]', 'needs: changes'),
            ("CODEXONE_WEB_STUBS_ONLY: '0'", "CODEXONE_WEB_STUBS_ONLY: '1'"),
            ('npm run test:e2e -- admin-live-real --workers=1', 'true'),
            ('CODEXONE_WEB_TEST_BINARY: ../.build/live/codexone', 'CODEXONE_WEB_TEST_BINARY: ../.build/debug/codexone'),
            ('run: ../scripts/verify.sh --web', 'run: npm run build'),
            ('backend-rust-scripts, frontend-live, devcontainer]', 'backend-rust-scripts, devcontainer]'),
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
            ('--release-probe "$RUNNER_TEMP/probe/RustGatewayProbe"', '--release-build'),
            ("if: needs.changes.outputs.rust == 'true'\n        run: |",
             "if: needs.changes.outputs.frontend == 'true'\n        run: |"),
            ('if [[ "$VERIFY_EVENT" == pull_request || "$VERIFY_EVENT" == push ]]; then', 'if true; then'),
            ('name: rust-gateway-probe', 'name: product-only'),
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
        selections = [(), ('rust',), ('frontend',), ('rust', 'frontend'),
                      ('devcontainer',), ('rust', 'storage'), ('rust', 'storage', 'frontend', 'devcontainer')]
        for selected in selections:
            required = {'changes', 'docs'}
            if 'rust' in selected:
                required.update({'backend-rust', 'backend-rust-scripts'})
            if 'rust' in selected or 'frontend' in selected:
                required.update({'backend-rust-build', 'frontend-live'})
            if 'devcontainer' in selected:
                required.add('devcontainer')
            needs = {job: {'result': 'success' if job in required else 'skipped'} for job in jobs}
            needs['changes']['outputs'] = {name: str(name in selected).lower()
                                          for name in ('rust', 'storage', 'frontend', 'devcontainer')}
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
            (['scripts/verify.sh'], {'rust', 'frontend'}),
            (['.github/workflows/verify.yml'], {'rust', 'storage', 'frontend', 'devcontainer'}),
            (['.github/workflows/release.yml'], {'rust', 'frontend'}),
            (['.github/dependabot.yml'], set()),
            (['deploy/Dockerfile'], {'rust', 'frontend'}),
            (['.dockerignore'], {'rust', 'frontend'}),
            (['scripts/verify_websocket.py'], {'rust'}),
            (['scripts/verify_admin_live.py'], {'rust'}),
            (['scripts/rust_compat/execution_recovery.py'], {'rust'}),
            (['fixtures/system-status.json'], {'rust', 'frontend'}),
            (['fixtures/provider-text-contract.json', 'fixtures/image-input/synthetic.jpg'], {'rust'}),
            (['Sources/CodexOne/CodexOneMain.swift', 'Package.swift'], set()),
            (['web/src/App.tsx'], {'frontend'}),
            (['rust/storage/src/migration.rs'], {'rust', 'storage'}),
            (['rust/maintenance/src/snapshot.rs'], {'rust', 'storage'}),
            (['.devcontainer/Dockerfile'], {'devcontainer'}),
            (['unknown-root-file'], {'rust', 'frontend'}),
            ([f'docs/{index:03}.md' for index in range(320)] + ['rust/gateway/Cargo.toml'], {'rust'}),
        ]
        for paths, expected in cases:
            with self.subTest(last_path=paths[-1]):
                result = subprocess.run(['bash', 'scripts/ci_changes.sh'], cwd=ROOT, check=True,
                                        input='\0'.join(paths) + '\0', capture_output=True, text=True)
                self.assertEqual({line.removesuffix('=true') for line in result.stdout.splitlines()
                                  if line.endswith('=true')}, expected)

    def test_keeps_migrated_Rust_checks_in_all_shard_modes(self):
        replacements = {
            'scripts/verify_accounts.py', 'scripts/verify_admin_round2.py',
            'scripts/rust_compat/execution_recovery.py', 'scripts/verify_key_maintenance.py',
            'scripts/verify_storage_pressure.py', 'scripts/verify_upstream_proxy.py', 'scripts/rust_compat/readiness.py',
        }
        for mode in ([], ['--pr']):
            suites = []
            for shard in ('1/4', '2/4', '3/4', '4/4'):
                cmd = [sys.executable, 'scripts/backend_shards.py', '--list', shard, *mode]
                batch = subprocess.check_output(cmd, cwd=ROOT, text=True).split()
                self.assertTrue(batch)
                suites.extend(batch)
            self.assertEqual(len(suites), len(set(suites)))
            self.assertLessEqual(replacements, set(suites))

    def test_rust_pr_and_release_shards_dispatch_their_protocol_modes(self):
        # Run the shell dispatcher without starting any gateway or provider.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'calls'
            binary = root / 'codexone'
            binary.touch(mode=0o755)
            probe = root / "RustGatewayProbe"
            probe.touch(mode=0o755)
            python = root / 'python3'
            python.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
if sys.argv[1] == 'scripts/backend_shards.py':
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
with open(os.environ['CALL_LOG'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
''')
            python.chmod(0o755)
            env = {**os.environ, 'CODEXONE_BACKEND_BIN_DIR': str(root),
                   'PATH': str(root) + os.pathsep + os.environ['PATH'], 'CALL_LOG': str(log),
                   'CODEXONE_STORAGE_PRESSURE_ROOT': str(root / 'pressure')}
            cmd = ['bash', 'scripts/verify.sh', '--backend-scripts', 'all', '--pr']
            subprocess.run(cmd, cwd=ROOT, env=env, check=True, capture_output=True)
            recorded = log.read_text().splitlines()
            calls = {path: args for path, *args in map(json.loads, recorded)}
            expected = subprocess.check_output(
                [sys.executable, 'scripts/backend_shards.py', '--list', 'all', '--pr'],
                cwd=ROOT, text=True).split()
            self.assertEqual(set(calls), set(expected))
            self.assertEqual(len(recorded), len(expected))
            for path, args in calls.items():
                if Path(path).name in ('verify_gateway_diagnostics.py', 'verify_key_export.py', 'verify_model_profiles_import.py'):
                    self.assertEqual(args, [])
                else:
                    self.assertEqual(args[:2], ['--binary', str(binary)])
            for name in ('verify_accounts.py', 'verify_admin_round2.py', 'verify_key_maintenance.py'):
                self.assertEqual(calls['scripts/' + name][2:], ['--rust-probe', str(probe)])
            self.assertEqual(calls['scripts/verify_upstream_proxy.py'][2:], ['--rust'])
            self.assertEqual(calls['scripts/verify_client_protocol.py'][2:], ['--expect-provider-eof'])
            self.assertEqual(calls['scripts/verify_snapshot_restore.py'][2:], ['--linked-paths'])
            self.assertEqual(calls['scripts/verify_admin_live.py'][2:], ['--backend', 'rust'])
            self.assertEqual({Path(path).name for path, args in calls.items() if '--smoke' in args}, {
                'verify_images.py', 'verify_response_finish.py', 'verify_text_contract.py',
                'verify_upload_deadline.py', 'verify_upstream_ws_body_limit.py', 'verify_upstream_zstd.py',
            })

            log.unlink()
            subprocess.run(cmd[:-1] + ['--release'], cwd=ROOT, env=env,
                           check=True, capture_output=True)
            release_calls = [json.loads(line) for line in log.read_text().splitlines()]
            full = subprocess.check_output(
                [sys.executable, 'scripts/backend_shards.py', '--list', 'all'],
                cwd=ROOT, text=True).split()
            self.assertCountEqual([call[0] for call in release_calls], full)
            self.assertTrue(all('--smoke' not in call for call in release_calls))
            self.assertIn(['scripts/verify_storage_pressure.py', '--binary', str(binary),
                           '--space-root', str(root / 'pressure')], release_calls)
            self.assertIn(['scripts/verify_client_protocol.py', '--binary', str(binary),
                           '--expect-provider-eof'], release_calls)


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
            ("--backend-scripts '${{ matrix.shard }}' --release", "--backend-scripts '${{ matrix.shard }}' --pr"),
            ('suite: [tls, installation, capacity]', 'suite: [tls, installation]'),
            ('scripts/verify_mixed_capacity.py --image', 'unchecked-capacity'),
            ('mixed-capacity-evidence', 'omitted-evidence'),
            ('/test/scripts/verify_live_overview_capacity.py --binary /output/codexone', '--skip-live-capacity'),
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

    def test_reject_test_harness_in_product(self):
        with self.assertRaisesRegex(AssertionError, 'must exclude the test harness'):
            check_release(self.release, self.dockerfile.replace('FROM scratch AS runtime\n',
                         'FROM scratch AS runtime\nCOPY --from=rust-probe /output/RustGatewayProbe /\n'),
                          self.tls, self.backend)

    def test_reject_omitted_original_verification(self):
        with self.assertRaisesRegex(AssertionError, 'Retain the release check'):
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
        for name in ('deploy/Dockerfile', 'deploy/tls-verification.Dockerfile'):
            text = (ROOT / name).read_text()
            for block in re.findall(r'RUN src=/etc/apt/sources.list.d/ubuntu.sources.*?(?=\n(?:WORKDIR|COPY|USER|FROM|RUN|ARG|$))', text, re.S):
                script = block.replace('\\\n', ' ').removeprefix('RUN ')
                blocks.append(script.split('    && groupadd --gid')[0])
        self.assertEqual(len(blocks), 3)
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
