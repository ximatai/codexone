#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
identity="$root/Sources/CodexOneCore/Application/Identity"
tests="$root/rust/identity-runtime/tests"
swiftc -swift-version 6 "$identity/AccountObservations.swift" "$identity/QuotaTrend.swift" "$tests/quota_oracle.swift" -o "$tmp/oracle"
"$tmp/oracle" > "$tmp/swift.json"
CODEXONE_SWIFT_QUOTA_RECORD="$tmp/swift.json" CODEXONE_RUST_QUOTA_RECORD="$tmp/rust.json" \
  cargo test --locked --manifest-path "$root/rust/identity-runtime/Cargo.toml" \
    --test contract passive_observation_preserves_success_on_failure_and_rejects_old_version
"$tmp/oracle" "$tmp/rust.json"
