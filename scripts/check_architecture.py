#!/usr/bin/env python3
"""Check the important declared module boundaries, not a fixed folder tree."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
targets = {target["name"]: target for target in package["targets"]}
assert not targets["CodexOneCore"]["dependencies"], "Core must not depend on frameworks or adapters"
for owner, forbidden in [("CodexOneAdapters", "CodexOneRuntime"), ("CodexOneRuntime", "CodexOneAdapters")]:
    for dependency in targets[owner]["dependencies"]:
        if "byName" in dependency:
            assert dependency["byName"][0] != forbidden, f"Forbidden dependency: {owner} -> {forbidden}"
print("PASS: Core is independent; Runtime and Adapters do not depend on each other.")
