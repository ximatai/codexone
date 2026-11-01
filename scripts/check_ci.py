#!/usr/bin/env python3
"""Check workflow pins that must move together without installing YAML dependencies."""

import json
from pathlib import Path
import re


def check():
    root = Path(__file__).resolve().parents[1]
    workflow = (root / '.github/workflows/verify.yml').read_text()
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
    cache_pins = re.findall(r'\$\{\{ runner.os \}\}-swift-([0-9a-f]{64})-', workflow)
    assert len(cache_pins) == 3 and set(cache_pins) == set(swift), 'Cache must follow the Swift digest'
    container = (root / '.devcontainer/Dockerfile').read_text()
    assert re.findall(r'^FROM swift:[^\s]+@sha256:([0-9a-f]{64})$', container, re.M) == [swift[0]], (
        'Dev container must use the CI Swift digest')
    node = re.findall(r'node-version: ([\d.]+)', workflow)
    assert node and set(node) == set(re.findall(r'^ARG NODE_VERSION=([\d.]+)$', container, re.M)), (
        'Dev container Node.js must match CI')
    print(f'PASS: Playwright {image[0]} matches lockfile; Swift build/shards/cache and dev container pins match')


if __name__ == '__main__':
    check()
