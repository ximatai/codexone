#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/rust/gateway/target}"
case "${1:-}" in
  --with-storage-tmpfs)
    shift
    root="$(mktemp -d)"
    mounted=false
    cleanup() {
      if [[ "$mounted" == true ]]; then
        sudo -n umount "$root"
      fi
      rmdir "$root"
    }
    trap cleanup EXIT
    sudo -n mount -t tmpfs -o "size=448m,uid=$(id -u),gid=$(id -g),mode=0700,nodev,nosuid,noexec" tmpfs "$root"
    mounted=true
    CODEXONE_TEST_TMPFS="$root" CODEXONE_STORAGE_PRESSURE_ROOT="$root" "$@"
    exit
    ;;
  --release-build)
    cargo build --locked --release --manifest-path rust/gateway/Cargo.toml --bin codexone
    exit
    ;;
  --release-probe)
    destination="${2:?Expected output path for RustGatewayProbe}"
    cargo test --locked --release --manifest-path rust/gateway/Cargo.toml --bin codexone \
      --no-run --message-format=json | python3 scripts/export_rust_probe.py "$destination"
    exit
    ;;
  --crate-tests) ;;
  '') cargo build --locked --manifest-path rust/gateway/Cargo.toml --bin codexone ;;
  *) echo "Usage: $0 [--release-build | --release-probe PATH | --crate-tests | --with-storage-tmpfs COMMAND]" >&2; exit 64 ;;
esac

# Cargo does not run dependency tests. Each standalone crate has its own lockfile.
for manifest in rust/*/Cargo.toml; do
  if [[ "$manifest" == rust/identity-runtime/Cargo.toml ]]; then
    cargo test --locked --manifest-path "$manifest" --features test-support
  else
    cargo test --locked --manifest-path "$manifest"
  fi
done

if [[ -n "${CODEXONE_TEST_TMPFS:-}" ]]; then
  cargo test --locked --manifest-path rust/maintenance/Cargo.toml --lib \
    snapshot::tests::restore_rechecks_capacity_between_copy_batches -- --exact --ignored
fi

if [[ "${1:-}" == --crate-tests ]]; then exit; fi

gateway="$CARGO_TARGET_DIR/debug/codexone"
python3 scripts/verify_process.py --binary "$gateway"
python3 scripts/verify_protocol.py --binary "$gateway"
python3 scripts/verify_websocket.py --binary "$gateway"
python3 scripts/verify_client_protocol.py --binary "$gateway" --expect-provider-eof
python3 scripts/verify_snapshot_restore.py --binary "$gateway" --linked-paths
