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
      scripts/verify.sh) backend=true; frontend=true; devcontainer=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*) ;;
      rust/*|scripts/verify_rust.sh|scripts/rust_compat/*) rust=true ;;
      deploy/Dockerfile|Tests/CodexOneAdaptersTests/Fixtures/*|scripts/browser_env.py|\
      scripts/verify_process.py|scripts/verify_protocol.py|scripts/verify_websocket.py|\
      scripts/verify_client_protocol.py|scripts/verify_snapshot_restore.py|\
      scripts/verify_admin.py|scripts/verify_keys.py) backend=true; rust=true ;;
      web/*) frontend=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|scripts/*|deploy/*) backend=true ;;
      *) backend=true; rust=true; frontend=true ;;
    esac
  done
fi
printf 'backend=%s\nrust=%s\nfrontend=%s\ndevcontainer=%s\n' "$backend" "$rust" "$frontend" "$devcontainer"
