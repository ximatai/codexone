#!/usr/bin/env bash
# Consume git diff --name-only -z (including both paths of renames via --no-renames).
set -euo pipefail
rust=false
storage=false
frontend=false
devcontainer=false
if [[ "${1:-}" == --all ]]; then
  rust=true
  storage=true
  frontend=true
  devcontainer=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--all] < changed-paths.nul" >&2
  exit 64
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/workflows/verify.yml|scripts/ci_changes.sh) rust=true; storage=true; frontend=true; devcontainer=true ;;
      .github/workflows/release.yml|.dockerignore|deploy/*) rust=true; frontend=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*|.github/*) ;;
      fixtures/system-status.json) rust=true; frontend=true ;;
      scripts/verify.sh) rust=true; frontend=true ;;
      rust/storage/*|rust/maintenance/*|rust/execution/src/reserve.rs|rust/gateway/src/online_backup.rs|\
      scripts/verify_storage_pressure.py) rust=true; storage=true ;;
      rust/*|scripts/*|fixtures/*) rust=true ;;
      web/*) frontend=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|.swift-version) ;;
      *) rust=true; frontend=true ;;
    esac
  done
fi
printf 'rust=%s\nstorage=%s\nfrontend=%s\ndevcontainer=%s\n' "$rust" "$storage" "$frontend" "$devcontainer"
