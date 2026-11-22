#!/usr/bin/env bash
# Consume git diff --name-only -z (including both paths of renames via --no-renames).
set -euo pipefail
rust=false
storage=false
frontend=false
admin_live_visual=false
devcontainer=false
if [[ "${1:-}" == --all ]]; then
  rust=true
  storage=true
  frontend=true
  admin_live_visual=true
  devcontainer=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--all] < changed-paths.nul" >&2
  exit 64
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/workflows/verify.yml|scripts/ci_changes.sh)
        rust=true; storage=true; frontend=true; admin_live_visual=true; devcontainer=true ;;
      .github/workflows/release.yml|.dockerignore|deploy/*) rust=true; frontend=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*|.github/*) ;;
      fixtures/system-status.json) rust=true; frontend=true; admin_live_visual=true ;;
      scripts/verify.sh) rust=true; frontend=true ;;
      rust/storage/*|rust/maintenance/*|rust/execution/src/reserve.rs|rust/gateway/src/online_backup.rs|\
      scripts/verify_storage_pressure.py) rust=true; storage=true ;;
      rust/gateway/src/overview_*.rs|rust/usage/src/overview.rs|rust/admin/src/assets.rs|\
      scripts/verify_admin_live.py|scripts/verify_admin.py|scripts/verify_keys.py|\
      scripts/verify_protocol.py|scripts/browser_env.py)
        rust=true; admin_live_visual=true ;;
      rust/*|scripts/*|fixtures/*) rust=true ;;
      web/src/features/system-status/*|web/src/features/usage/*|\
      web/src/features/account-management/QuotaWindowBar.tsx|web/src/features/account-management/quota.ts|\
      web/src/features/account-management/accounts.module.css|web/src/features/account-management/api.ts|\
      web/src/app/*|web/src/shared/*|web/src/App.tsx|web/src/main.tsx|web/src/styles.css|\
      web/index.html|web/package*.json|web/playwright.config.ts|web/vite.config.ts|web/theme-plugin.ts|web/tsconfig.json|\
      web/tests/e2e/admin-live-real.spec.ts|web/tests/e2e/layout.ts)
        frontend=true; admin_live_visual=true ;;
      web/*) frontend=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|.swift-version) ;;
      *) rust=true; frontend=true ;;
    esac
  done
fi
printf 'rust=%s\nstorage=%s\nfrontend=%s\nadmin_live_visual=%s\ndevcontainer=%s\n' \
  "$rust" "$storage" "$frontend" "$admin_live_visual" "$devcontainer"
