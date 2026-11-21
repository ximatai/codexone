#!/usr/bin/env python3
"""Check CI pins and optimized release gates without installing YAML dependencies."""

import json
from pathlib import Path
import re


def workflow_jobs(source):
    """Read top-level jobs only; keep this policy check dependency-free."""
    headings = list(re.finditer(r'^  ([a-z][a-z-]*):\n', source.split('jobs:\n', 1)[1], re.M))
    jobs = source.split('jobs:\n', 1)[1]
    return {heading[1]: jobs[heading.end():headings[index + 1].start()
                            if index + 1 < len(headings) else len(jobs)]
            for index, heading in enumerate(headings)}


def check_release(release, dockerfile, tls, backend_scripts):
    jobs = workflow_jobs(release)
    assert set(jobs) == {'build', 'backend-scripts', 'image-checks', 'verify', 'publish', 'release'}, (
        'Release jobs must retain build, every verification suite, gate and publication')
    assert 'needs: [build, backend-scripts, image-checks]' in jobs['verify'], 'Gate must require all checks'
    assert 'if: always()' in jobs['verify'], 'Gate must run after failed or skipped dependencies'
    assert "if result != 'success':" in jobs['verify'], 'Gate must reject failure, cancellation and skips'
    assert re.search(r'^    needs: verify$', jobs['publish'], re.M), 'Publish must depend on the gate'
    for name in ('publish', 'release'):
        assert "if: github.event_name == 'push'" in jobs[name], 'Dry-runs must never publish'
    assert 'net.ximatai.codexone.backend="rust"' in dockerfile, 'Docker must identify its Rust runtime'
    assert '''FROM scratch AS verification-export
COPY --from=backend-rust /output/codexone /
COPY --from=rust-probe /output/RustGatewayProbe /''' in dockerfile, (
        'Extract the product and the separate test harness')
    product = dockerfile.split('FROM scratch AS runtime\n', 1)[1]
    assert 'RustGatewayProbe' not in product and 'rust-probe' not in product, (
        'The runtime must exclude the test harness')
    assert '--no-run --message-format=json' in dockerfile and 'scripts/export_rust_probe.py' in dockerfile, (
        'Export the unique Cargo test executable')
    assert 'CODEXONE_BACKEND=' not in jobs['build'], 'Release must exercise the only product backend'
    assert '''test "$(docker image inspect codexone:candidate --format '{{index .Config.Labels "net.ximatai.codexone.backend"}}')" = rust''' in jobs['build'], (
        'Check the candidate backend before exporting')
    assert 'shard: [1/4, 2/4, 3/4, 4/4]' in jobs['backend-scripts'], 'Release must run all four shards'
    assert 'suite: [tls, installation, capacity]' in jobs['image-checks'], 'Release must run TLS, installation and mixed capacity'
    assert 'scripts/verify_mixed_capacity.py --image' in jobs['image-checks'], 'Run capacity against the exact candidate image'
    assert 'mixed-capacity-evidence' in jobs['image-checks'], 'Save resource gate evidence'
    assert '/test/scripts/verify_live_overview_capacity.py --binary /output/codexone' in jobs['image-checks'], 'Require slow viewer isolation on the candidate gateway'
    for name in ('backend-scripts', 'image-checks'):
        assert 'fail-fast: false' in jobs[name], 'Collect results from all verification jobs'
        assert 'needs: build' in jobs[name], 'Checks must consume the current build'
        assert 'ref: ${{ needs.build.outputs.revision }}' in jobs[name], 'Checkout the resolved build commit'
    shards = jobs['backend-scripts']
    shard_command = "codexone:verification-tools bash scripts/verify.sh --backend-scripts '${{ matrix.shard }}' --release"
    assert shard_command in {line.strip() for line in shards.splitlines()}, 'Use the complete shard entry point'
    assert '--network none' in shards and 'CODEXONE_BACKEND_BIN_DIR=/binaries' in shards, (
        'Optimized shard checks must run offline against the downloaded executables')
    assert '"$BINARIES_ARCHIVE_SHA256" | sha256sum --check -' in shards, 'Check the binary archive against build output'
    assert '--target verification-export' in jobs['build'], 'Build the optimized probe without serial tests'
    assert set(re.findall(r'--target ([\w-]+)', jobs['build'])) == {'verification-export'}, (
        'Build cache must never contain verification RUN layers')
    assert 'build_cache:' in release and 'USE_BUILD_CACHE' in jobs['build'], 'Keep cold-build measurement available'
    cache_epochs = re.findall(r'-release-buildkit-v([1-9][0-9]*)-' + re.escape(
        "${{ hashFiles('deploy/Dockerfile', '.github/workflows/release.yml') }}-"), jobs['build'])
    assert len(cache_epochs) == 2 and len(set(cache_epochs)) == 1, (
        'Release cache must be isolated and follow all Dockerfile/workflow toolchain pins')
    assert re.search(r'--driver-opt image=moby/buildkit:v[\d.]+@sha256:[0-9a-f]{64}\b', jobs['build']), (
        'The release BuildKit daemon must be digest-pinned')
    assert '${{ steps.metadata.outputs.revision }}' in jobs['build'], 'Cache must identify the resolved build source'
    assert 'cmp binaries/codexone optimized-output/codexone' in jobs['build'], 'Candidate and build binary must match'
    assert 'docker cp "$container:/usr/local/bin/codexone" binaries/codexone' in jobs['build'], (
        'Shards must verify the executable extracted from the candidate image')
    for name in ('image-checks', 'verify', 'publish'):
        assert '"$IMAGE_ARCHIVE_SHA256" | sha256sum --check -' in jobs[name], (
            f'{name} must check the image archive against the build/gate output')
        assert 'sha256sum --check SHA256SUMS' in jobs[name], f'{name} must verify release file checksums'
    for artifact in ('verified-release-files', 'verified-linux-amd64-image'):
        assert f'name: {artifact}\n' in jobs['verify'] and f'name: {artifact}\n' in jobs['publish'], (
            'Only the successful gate may hand verified artifacts to publish')
        assert f'name: {artifact}\n' not in jobs['build'], 'Build artifacts are still candidates'
    assert "--image \"$(cat artifacts/image-id.txt)\"" in jobs['image-checks'], 'Install the exact candidate image'
    assert 'verify_tls_proxy.py --binary /output/codexone' in jobs['image-checks'], 'Retain TLS checks'
    for limit in ('--network none', '--read-only --user 10001:10001', '--cap-drop ALL',
                  '--security-opt no-new-privileges:true', '--pids-limit 128 --memory 768m'):
        assert limit in jobs['image-checks'], f'Retain TLS isolation: {limit}'
    assert 'COPY --from=bundle /usr/local/bin/codexone /output/codexone' in tls, 'TLS must use the candidate binary'
    assert 'COPY --from=bundle /opt/codexone/web/ /test/web/dist/' in tls, 'TLS must use the candidate SPA'
    assert 'docker build' not in jobs['publish'] and 'buildx' not in jobs['publish'], 'Publish must never rebuild'
    assert 'subject-digest: ${{ steps.push.outputs.digest }}' in jobs['publish'], 'Attest the pushed digest'
    assert '''test "$(docker image inspect "$IMAGE@$digest" --format '{{.Id}}')" = "$(cat artifacts/image-id.txt)"''' in jobs['publish'], (
        'The pushed digest must resolve to the verified image ID')
    assert '--tmpfs /pressure:rw,noexec,nosuid,size=448m,mode=0700' in shards, (
        'Release must exercise disk pressure on a dedicated bounded tmpfs')
    assert 'codexone RustGatewayProbe' in jobs['build'], 'Release shards need the isolated test harness'
    for suite in ('verify_protocol.py', 'verify_accounts.py', 'verify_key_maintenance.py',
                  'verify_admin_round2.py', 'verify_storage_pressure.py', 'verify_upstream_proxy.py',
                  'rust_compat/execution_recovery.py', 'rust_compat/readiness.py'):
        assert f'run_check scripts/{suite} --binary "$binary"' in backend_scripts, (
            f'Retain the release check for {suite}')


def check_live_browser(workflow):
    jobs = workflow_jobs(workflow)
    assert set(jobs) == {'changes', 'docs', 'backend-rust', 'backend-rust-build',
                         'backend-rust-scripts', 'frontend-live', 'devcontainer', 'verify'}, (
        'Verify should have one Rust build, one set of shards and one browser job')
    gate_needs = re.search(r'^    needs: \[([^\n]+)\]$', jobs['verify'], re.M)
    assert gate_needs and set(gate_needs[1].split(', ')) == jobs.keys() - {'verify'}, 'Verify must await every job'
    live = jobs['frontend-live']
    assert 'needs: [changes, backend-rust-build]' in live, 'Real browser must depend on the product build'
    assert "needs.changes.outputs.rust == 'true' || needs.changes.outputs.frontend == 'true'" in live, (
        'Real browser must follow both backend and frontend changes')
    assert 'name: backend-rust-binaries' in live and 'digest-mismatch: error' in live, (
        'Real browser must restore the matching product binary')
    assert 'rust-gateway-probe' not in live, 'Browser tests do not use the test harness'
    assert 'CODEXONE_WEB_TEST_BINARY: ../.build/live/codexone' in live, 'Real browser must use the restored gateway'
    assert "CODEXONE_WEB_STUBS_ONLY: '0'" in live, 'Real browser must run its gateway tests'
    assert 'npm run test:e2e -- admin-live-real --workers=1' in live, 'Retain real gateway browser checks'
    assert '''        if: needs.changes.outputs.frontend == 'true'
        env:
          CODEXONE_WEB_STUBS_ONLY: '1'
        run: ../scripts/verify.sh --web''' in live, 'Run isolated browser checks and reuse their SPA build'
    assert "if: needs.changes.outputs.frontend != 'true'\n        run: npm run build" in live, (
        'Build the SPA once per browser job')


def check_rust(workflow, dockerfile):
    jobs = workflow_jobs(workflow)
    tests, build, shards = (jobs[name] for name in (
        'backend-rust', 'backend-rust-build', 'backend-rust-scripts'))
    for job in (tests, build):
        version = re.search(r'^      RUSTUP_TOOLCHAIN: ([\d.]+)$', job, re.M)
        assert version and f'ARG RUST_BUILD_IMAGE=rust:{version[1]}-' in dockerfile, (
            'Verify and the Rust candidate must use the same Rust version')
    for job in (tests, shards):
        assert "    if: needs.changes.outputs.rust == 'true'\n" in job, 'Rust checks must follow Rust selection'
    assert "    if: needs.changes.outputs.rust == 'true' || needs.changes.outputs.frontend == 'true'\n" in build, (
        'Rust protocol and frontend-only changes must both build the optimized gateway')
    assert './scripts/verify_rust.sh --with-storage-tmpfs ./scripts/verify_rust.sh --crate-tests' in tests, 'Retain Rust crate tests'
    assert './scripts/verify_rust.sh --release-build' in build and '-C rust/gateway/target/release codexone' in build, (
        'Package the optimized product gateway')
    assert '''      - name: Build the isolated Rust gateway probe
        if: needs.changes.outputs.rust == 'true'
        run: |
          ./scripts/verify_rust.sh --release-probe "$RUNNER_TEMP/probe/RustGatewayProbe"''' in build, (
        'Build the test harness only for Rust checks')
    assert 'needs: [changes, backend-rust-build]' in shards, 'Rust checks need the matching build'
    assert 'shard: [1/4, 2/4, 3/4, 4/4]' in shards, 'Rust must run all four protocol shards'
    for artifact in ('backend-rust-binaries', 'rust-gateway-probe'):
        assert f'digest-mismatch: error\n          name: {artifact}' in shards, (
            'Restore the matching product and test executables')
    assert "./scripts/verify.sh --backend-scripts '${{ matrix.shard }}' \"${args[@]}\"" in shards, (
        'Use the same Rust protocol dispatcher in every shard')
    assert '''if [[ "$VERIFY_EVENT" == pull_request || "$VERIFY_EVENT" == push ]]; then
            args+=(--pr)''' in shards, 'Use quick checks for ordinary Verify and full checks on dispatch'


def check():
    root = Path(__file__).resolve().parents[1]
    workflow = (root / '.github/workflows/verify.yml').read_text()
    release = (root / '.github/workflows/release.yml').read_text()
    dockerfile = (root / 'deploy/Dockerfile').read_text()
    tls = (root / 'deploy/tls-verification.Dockerfile').read_text()
    pins = {}
    for action, pin in re.findall(r'uses: ([\w/-]+)@([^\s]+)', workflow + release):
        assert re.fullmatch(r'[0-9a-f]{40}', pin), f'Action must be SHA-pinned: {action}'
        family = 'actions/cache' if action.startswith('actions/cache/') else action
        assert pins.setdefault(family, pin) == pin, f'Action pins must move together: {family}'
    lock = json.loads((root / 'web/package-lock.json').read_text())
    versions = {
        lock['packages'][f'node_modules/{package}']['version']
        for package in ('@playwright/test', 'playwright', 'playwright-core')
    }
    image = re.findall(
        r'image: mcr\.microsoft\.com/playwright:v([\d.]+)-noble@sha256:[0-9a-f]{64}\b',
        workflow,
    )
    assert len(image) == 1 and versions == set(image), (
        f'Update the Playwright image tag AND registry digest with the lockfile: {versions}, image={image}'
    )
    rust = re.findall(r'^ARG RUST_BUILD_IMAGE=(rust:[^\s]+@sha256:[0-9a-f]{64})$', dockerfile, re.M)
    runtime = re.findall(r'^ARG RUST_RUNTIME_IMAGE=(ubuntu:[^\s]+@sha256:[0-9a-f]{64})$', dockerfile, re.M)
    container = (root / '.devcontainer/Dockerfile').read_text()
    assert len(rust) == 1 and f'FROM {rust[0]}\n' in container, 'Dev container must use the release Rust pin'
    assert len(runtime) == 1 and f'ARG TEST_BASE={runtime[0]}\n' in tls, (
        'TLS harness and candidate must use the same Ubuntu runtime pin')
    node = re.findall(r'node-version: ([\d.]+)', workflow)
    assert node and set(node) == set(re.findall(r'^ARG NODE_VERSION=([\d.]+)$', container, re.M)), (
        'Dev container Node.js must match CI')
    check_release(release, dockerfile, tls, (root / 'scripts/verify.sh').read_text())
    check_live_browser(workflow)
    check_rust(workflow, dockerfile)
    print(f'PASS: Playwright {image[0]} matches lockfile; Rust, Ubuntu and Node.js pins match')
    print('PASS: Rust toolchain and Verify gate, Actions pins, optimized release coverage, immutable artifacts and TLS match policy')


if __name__ == '__main__':
    check()
