#!/usr/bin/env bash
# Consume git diff --name-only -z (including both paths of renames via --no-renames).
set -euo pipefail
backend=false
rust=false
frontend=false
devcontainer=false
if [[ "${1:-}" == --all ]]; then
  backend=true
  rust=true
  frontend=true
  devcontainer=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--all] < changed-paths.nul" >&2
  exit 64
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/*|scripts/ci_changes.sh) backend=true; rust=true; frontend=true; devcontainer=true ;;
      scripts/verify.sh) backend=true; rust=true; frontend=true; devcontainer=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*) ;;
      scripts/rust_compat/compare.py|rust/storage/*|rust/maintenance/*|\
      Sources/CodexOneAdapters/Persistence/*|Sources/CodexOneCore/Application/Execution/OnlineBackup.swift|\
      Sources/CodexOneRuntime/OnlineBackupSupervisor.swift|rust/gateway/src/*maintenance*|\
      deploy/*|Tests/CodexOneAdaptersTests/Fixtures/*) backend=true; rust=true ;;
      rust/*|scripts/verify_rust.sh|scripts/rust_compat/*) rust=true ;;
      web/*) rust=true; frontend=true ;;
      # Shared suites also import helpers from existing Swift test scripts.
      scripts/*) backend=true; rust=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|.swift-version) backend=true ;;
      *) backend=true; rust=true; frontend=true ;;
    esac
  done
fi
printf 'backend=%s\nrust=%s\nfrontend=%s\ndevcontainer=%s\n' "$backend" "$rust" "$frontend" "$devcontainer"
