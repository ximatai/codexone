#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

backend_build() {
  local swiftpm_flags=()
  if [[ "${CODEXONE_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swiftpm_flags+=(--disable-sandbox)
  fi
  swift format lint --strict --recursive Sources Tests Package.swift
  swift build "${swiftpm_flags[@]}" --build-tests -j "${CODEXONE_BUILD_JOBS:-4}"
  swift test "${swiftpm_flags[@]}" --skip-build --no-parallel -j "${CODEXONE_BUILD_JOBS:-4}"
}

backend_scripts() {
  python3 scripts/backend_shards.py --check
  local backend_selected backend_bin_dir
  backend_selected="$(python3 scripts/backend_shards.py --list "${1:-all}")"
  backend_bin_dir="${CODEXONE_BACKEND_BIN_DIR:-.build/debug}"
  for binary in codexone ExecutionProbe; do
    if [[ ! -x "$backend_bin_dir/$binary" ]]; then
      echo "Missing executable: $backend_bin_dir/$binary; run $0 --backend-build first" >&2
      return 1
    fi
  done
  run_check scripts/verify_storage_pressure.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_key_maintenance.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_snapshot_restore.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_process.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_execution.py --binary "$backend_bin_dir/ExecutionProbe"
  run_check scripts/verify_accounts.py --binary "$backend_bin_dir/ExecutionProbe"
  run_check scripts/verify_protocol.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_gateway_diagnostics.py
  run_check scripts/verify_client_protocol.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_websocket.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_protocol_rejections.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_upstream_proxy.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_upstream_events.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_codex_shapes.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_text_contract.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_request_parameters.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_turn_diagnostics.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_optional_reasoning.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_context.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_compaction_stream.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_images.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_migration_readiness.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_control.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_keys.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_model_profiles_import.py
  run_check scripts/verify_key_export.py
  run_check scripts/verify_key_import.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_trial_provider.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_lite.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_admin.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_admin_round2.py --binary "$backend_bin_dir/codexone" --probe "$backend_bin_dir/ExecutionProbe"
  run_check scripts/verify_admin_assets.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_pool_config.py --binary "$backend_bin_dir/codexone"
  run_check scripts/verify_migration_cutback.py --binary "$backend_bin_dir/codexone"
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

backend() {
  python3 scripts/check_docs.py
  python3 scripts/check_architecture.py
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
  --backend-scripts) backend_scripts "${2:?Expected shard i/4}" ;;
  --web) frontend "${2:-}" ;;
  all) backend; frontend ;;
  *) echo "Usage: $0 [--backend | --backend-build | --backend-scripts i/4 | --web [--chrome] | --client --binary PATH --codex PATH --expected-version VERSION [--require-lite]]" >&2; exit 64 ;;
esac
