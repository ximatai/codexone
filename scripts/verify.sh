#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

backend() {
  python3 scripts/check_docs.py
  python3 scripts/check_architecture.py
  swift format lint --strict --recursive Sources Tests Package.swift
  swift build -j "${CODEXONE_BUILD_JOBS:-4}"
  swift test -j "${CODEXONE_BUILD_JOBS:-4}"
  local backend_bin_dir
  backend_bin_dir="$(swift build --show-bin-path)"
  python3 scripts/verify_process.py --binary "$backend_bin_dir/codexone"
}

frontend() {
  (
    cd web
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
  --backend) backend ;;
  --web) frontend "${2:-}" ;;
  all) backend; frontend ;;
  *) echo "Usage: $0 [--backend | --web [--chrome]]" >&2; exit 64 ;;
esac
