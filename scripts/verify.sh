#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

backend_scripts() {
  python3 scripts/backend_shards.py --check
  local backend_selected
  local backend_bin_dir="${CODEXONE_BACKEND_BIN_DIR:-${CARGO_TARGET_DIR:-rust/gateway/target}/release}"
  local binary="$backend_bin_dir/codexone" probe="$backend_bin_dir/RustGatewayProbe"
  local shard_args=() smoke_args=() storage_args=()
  if [[ -n "${CODEXONE_STORAGE_PRESSURE_ROOT:-}" ]]; then
    storage_args+=(--space-root "$CODEXONE_STORAGE_PRESSURE_ROOT")
  fi
  case "${2:-}" in
    --pr) shard_args+=(--pr); smoke_args+=(--smoke) ;;
    --release)
      : "${CODEXONE_STORAGE_PRESSURE_ROOT:?Expected dedicated Linux tmpfs}"
      ;;
    "") ;;
    *) echo "Unknown backend scripts mode: $2" >&2; return 64 ;;
  esac
  backend_selected="$(python3 scripts/backend_shards.py --list "${1:-all}" ${shard_args[@]+"${shard_args[@]}"})"
  if [[ ! -x "$binary" ]]; then
    echo "Missing executable: $binary" >&2
    return 1
  fi
  case " $backend_selected " in
    *" scripts/verify_accounts.py "*|*" scripts/verify_admin_round2.py "*|*" scripts/verify_key_maintenance.py "*)
      if [[ ! -x "$probe" ]]; then
        echo "Missing test executable: $probe" >&2
        return 1
      fi
      ;;
  esac
  run_check scripts/verify_storage_pressure.py --binary "$binary" ${storage_args[@]+"${storage_args[@]}"}
  run_check scripts/verify_key_maintenance.py --binary "$binary" --rust-probe "$probe"
  run_check scripts/verify_snapshot_restore.py --binary "$binary" --linked-paths
  run_check scripts/verify_process.py --binary "$binary"
  run_check scripts/rust_compat/execution_recovery.py --binary "$binary"
  run_check scripts/rust_compat/readiness.py --binary "$binary"
  run_check scripts/verify_accounts.py --binary "$binary" --rust-probe "$probe"
  run_check scripts/verify_protocol.py --binary "$binary"
  run_check scripts/verify_gateway_diagnostics.py
  run_check scripts/verify_client_protocol.py --binary "$binary" --expect-provider-eof
  run_check scripts/verify_websocket.py --binary "$binary"
  run_check scripts/verify_upstream_ws_body_limit.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_upload_deadline.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_slow_ingress.py --binary "$binary"
  run_check scripts/verify_response_finish.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_protocol_rejections.py --binary "$binary"
  run_check scripts/verify_upstream_zstd.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_ws_address_candidates.py --binary "$binary"
  run_check scripts/verify_upstream_proxy.py --binary "$binary" --rust
  run_check scripts/verify_upstream_events.py --binary "$binary"
  run_check scripts/verify_codex_shapes.py --binary "$binary"
  run_check scripts/verify_text_contract.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_json_order.py --binary "$binary"
  run_check scripts/verify_upstream_json.py --binary "$binary" --require-stable
  run_check scripts/verify_request_parameters.py --binary "$binary"
  run_check scripts/verify_turn_diagnostics.py --binary "$binary"
  run_check scripts/verify_optional_reasoning.py --binary "$binary"
  run_check scripts/verify_context.py --binary "$binary"
  run_check scripts/verify_compaction_stream.py --binary "$binary"
  run_check scripts/verify_images.py --binary "$binary" ${smoke_args[@]+"${smoke_args[@]}"}
  run_check scripts/verify_migration_readiness.py --binary "$binary"
  run_check scripts/verify_control.py --binary "$binary"
  run_check scripts/verify_home_panel.py --binary "$binary"
  run_check scripts/verify_business_day.py --binary "$binary"
  run_check scripts/verify_keys.py --binary "$binary"
  run_check scripts/verify_model_profiles_import.py
  run_check scripts/verify_key_export.py
  run_check scripts/verify_key_import.py --binary "$binary"
  run_check scripts/verify_trial_provider.py --binary "$binary"
  run_check scripts/verify_lite.py --binary "$binary"
  run_check scripts/verify_admin_live.py --binary "$binary" --backend rust
  run_check scripts/verify_admin.py --binary "$binary"
  run_check scripts/verify_admin_round2.py --binary "$binary" --rust-probe "$probe"
  run_check scripts/verify_admin_assets.py --binary "$binary"
  run_check scripts/verify_pool_config.py --binary "$binary"
  run_check scripts/verify_migration_cutback.py --binary "$binary"
}

run_check() {
  case " $backend_selected " in
    *" $1 "*)
      local started=$SECONDS
      echo "RUN: $1"
      python3 "$@"
      echo "PASS: $1 ($((SECONDS - started))s)"
      ;;
  esac
}

backend_build() {
  local binary_directory="${CARGO_TARGET_DIR:-rust/gateway/target}/release"
  scripts/verify_rust.sh --release-build
  scripts/verify_rust.sh --release-probe "$binary_directory/RustGatewayProbe"
}

backend() {
  python3 scripts/check_docs.py
  scripts/verify_rust.sh --crate-tests
  backend_build
  backend_scripts all
}

frontend() {
  (
    cd web
    npm run lint
    npm run format:check
    npm test
    # build includes typecheck; Playwright only serves this bundle via preview.
    npm run build
    if [[ "${1:-}" == "--chrome" ]]; then
      npm run test:e2e:chrome
    else
      npm run test:e2e
    fi
  )
}

case "${1:-all}" in
  --client) shift; python3 scripts/verify_default_client.py "$@" ;;
  --backend) backend ;;
  --backend-build) backend_build ;;
  --backend-scripts)
    shard="${2:?Expected shard i/4|all}"
    shift 2
    mode=''
    case "${1:-}" in
      --pr|--release) mode=$1; shift ;;
    esac
    if (( $# )); then echo "Unexpected backend scripts arguments: $*" >&2; exit 64; fi
    backend_scripts "$shard" "$mode"
    ;;
  --web) frontend "${2:-}" ;;
  all) backend; frontend ;;
  *) echo "Usage: $0 [--backend | --backend-build | --backend-scripts i/4|all [--pr|--release] | --web [--chrome] | --client --binary PATH --codex PATH --expected-version VERSION [--require-lite]]" >&2; exit 64 ;;
esac
