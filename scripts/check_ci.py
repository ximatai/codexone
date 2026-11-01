#!/usr/bin/env python3
"""Check workflow pins that must move together without installing YAML dependencies."""

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
    assert 'shard: [1/4, 2/4, 3/4, 4/4]' in jobs['backend-scripts'], 'Release must run all four shards'
    assert 'suite: [tls, installation]' in jobs['image-checks'], 'Release must run TLS and installation'
    for name in ('backend-scripts', 'image-checks'):
        assert 'fail-fast: false' in jobs[name], 'Collect results from all verification jobs'
        assert 'needs: build' in jobs[name], 'Checks must consume the current build'
        assert 'ref: ${{ needs.build.outputs.revision }}' in jobs[name], 'Checkout the resolved build commit'
    shards = jobs['backend-scripts']
    assert "scripts/verify.sh --backend-scripts '${{ matrix.shard }}'" in shards, 'Use the complete shard entry point'
    assert '--network none' in shards and 'CODEXONE_BACKEND_BIN_DIR=/binaries' in shards, (
        'Optimized shard checks must run offline against the downloaded executables')
    assert '"$BINARIES_ARCHIVE_SHA256" | sha256sum --check -' in shards, 'Check the binary archive against build output'
    assert '--target verification-export' in jobs['build'], 'Build the optimized probe without serial tests'
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
    assert '--target verification ' not in jobs['build'], 'Do not cache or serialize release verification'
    assert 'docker build' not in jobs['publish'] and 'buildx' not in jobs['publish'], 'Publish must never rebuild'
    assert 'subject-digest: ${{ steps.push.outputs.digest }}' in jobs['publish'], 'Attest the pushed digest'
    assert '''test "$(docker image inspect "$IMAGE@$digest" --format '{{.Id}}')" = "$(cat artifacts/image-id.txt)"''' in jobs['publish'], (
        'The pushed digest must resolve to the verified image ID')
    release_checks = set(re.findall(r'python3 scripts/(verify_\w+\.py)', dockerfile))
    shard_checks = set(re.findall(r'^  run_check scripts/(verify_\w+\.py)', backend_scripts, re.M))
    assert release_checks and release_checks <= shard_checks, (
        f'Release shards must retain every Dockerfile verification: {sorted(release_checks - shard_checks)}')


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
    assert len(image) == 1 and versions == {image[0]}, (
        f'Update the Playwright image tag AND registry digest with the lockfile: {versions}, image={image}'
    )
    swift = re.findall(r'container: swift:[^\s]+@sha256:([0-9a-f]{64})\b', workflow)
    assert len(swift) == 2 and len(set(swift)) == 1, 'Build and shards must use the same Swift image'
    assert re.findall(r'^ARG SWIFT_BUILD_IMAGE=swift:[^\s]+@sha256:([0-9a-f]{64})$', dockerfile, re.M) == [swift[0]], (
        'Release tools and optimized build must match the CI Swift digest')
    runtime = re.findall(r'^ARG SWIFT_RUNTIME_IMAGE=(swift:[^\s]+)$', dockerfile, re.M)
    assert runtime and re.findall(r'^ARG TEST_BASE=(swift:[^\s]+)$', tls, re.M) == runtime, (
        'TLS harness and candidate must use the same Swift runtime pin')
    cache_pins = re.findall(r'\$\{\{ runner.os \}\}-swift-([0-9a-f]{64})-', workflow)
    assert len(cache_pins) == 3 and set(cache_pins) == set(swift), 'Cache must follow the Swift digest'
    container = (root / '.devcontainer/Dockerfile').read_text()
    assert re.findall(r'^FROM swift:[^\s]+@sha256:([0-9a-f]{64})$', container, re.M) == [swift[0]], (
        'Dev container must use the CI Swift digest')
    node = re.findall(r'node-version: ([\d.]+)', workflow)
    assert node and set(node) == set(re.findall(r'^ARG NODE_VERSION=([\d.]+)$', container, re.M)), (
        'Dev container Node.js must match CI')
    check_release(release, dockerfile, tls, (root / 'scripts/verify.sh').read_text())
    print(f'PASS: Playwright {image[0]} matches lockfile; Swift build/shards/cache and dev container pins match')
    print('PASS: Actions pins, optimized release coverage, immutable artifacts, TLS and publication gate match policy')


if __name__ == '__main__':
    check()
