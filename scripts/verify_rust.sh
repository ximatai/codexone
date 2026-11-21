#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/rust/gateway/target}"
case "${1:-}" in
  --release-build)
    cargo build --locked --release --manifest-path rust/gateway/Cargo.toml --bin codexone
    exit
    ;;
  --crate-tests) ;;
  '') cargo build --locked --manifest-path rust/gateway/Cargo.toml --bin codexone ;;
  *) echo "Usage: $0 [--release-build | --crate-tests]" >&2; exit 64 ;;
esac

# Cargo does not run dependency tests. Each standalone crate has its own lockfile.
for manifest in rust/*/Cargo.toml; do
  cargo test --locked --manifest-path "$manifest"
done

if [[ "${1:-}" == --crate-tests ]]; then exit; fi

gateway="$CARGO_TARGET_DIR/debug/codexone"
python3 scripts/verify_process.py --binary "$gateway"
python3 scripts/verify_protocol.py --binary "$gateway"
python3 scripts/verify_websocket.py --binary "$gateway"
python3 scripts/verify_client_protocol.py --binary "$gateway" --expect-provider-eof
python3 scripts/verify_snapshot_restore.py --binary "$gateway" --linked-paths
