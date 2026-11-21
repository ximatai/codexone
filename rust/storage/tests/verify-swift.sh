#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
manifest="$test_dir/../Cargo.toml"
repo=$(git -C "$test_dir" rev-parse --show-toplevel)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# Stage the compatibility baseline from docs/changes/rust-backend/proposal.md.
swift_ref=3c82d71f47b1c14a05a1e450fcd29b3061755aec
git -C "$repo" archive "$swift_ref" Package.swift Package.resolved Sources Tests | tar -x -C "$stage"
cp "$test_dir/swift/StorageInteropTests.swift" "$stage/Tests/CodexOneAdaptersTests/"
CARGO_TARGET_DIR="$stage/rust-target" cargo test --locked --manifest-path "$manifest" \
  --test swift_database --no-run --message-format=json > "$stage/rust-build.json"
CODEXONE_STORAGE_RUST_TEST=$(python3 - "$stage/rust-build.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as records:
    for line in records:
        record = json.loads(line)
        if record.get("reason") == "compiler-artifact" and record["target"]["name"] == "swift_database":
            print(record["executable"])
            break
    else:
        sys.exit("Rust interoperability test executable was not built")
PY
)
export CODEXONE_STORAGE_RUST_TEST
swift test --package-path "$stage" --filter swiftRustStorageInteroperability "$@"
