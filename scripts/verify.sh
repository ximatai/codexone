#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

backend() {
  python3 scripts/check_docs.py
  python3 scripts/check_architecture.py
  swift format lint --strict --recursive Sources Tests Package.swift
  swift build -j "${CODEXONE_BUILD_JOBS:-4}"
  swift test --no-parallel -j "${CODEXONE_BUILD_JOBS:-4}"
  local backend_bin_dir
  backend_bin_dir="$(swift build --show-bin-path)"
  python3 scripts/verify_storage_pressure.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_key_maintenance.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_snapshot_restore.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_process.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_execution.py --binary "$backend_bin_dir/ExecutionProbe"
  python3 scripts/verify_accounts.py --binary "$backend_bin_dir/ExecutionProbe"
  python3 scripts/verify_protocol.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_websocket.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_protocol_rejections.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_upstream_proxy.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_upstream_events.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_upstream_extensions.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_text_contract.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_tool_diagnostics.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_optional_reasoning.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_context.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_compaction_stream.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_images.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_keys.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_key_export.py
  python3 scripts/verify_key_import.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_trial_provider.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_lite.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_admin.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_admin_assets.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_pool_config.py --binary "$backend_bin_dir/codexone"
  python3 scripts/verify_migration_cutback.py --binary "$backend_bin_dir/codexone"
}

frontend() {
  (
    cd web
    npm run lint
    npm run format:check
    npm run typecheck
    npm test
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
  --web) frontend "${2:-}" ;;
  all) backend; frontend ;;
  *) echo "Usage: $0 [--backend | --web [--chrome] | --client --binary PATH --codex PATH --expected-version VERSION [--require-lite]]" >&2; exit 64 ;;
esac
