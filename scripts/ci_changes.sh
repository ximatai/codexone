#!/usr/bin/env bash
# Consume git diff --name-only -z (including both paths of renames via --no-renames).
set -euo pipefail
backend=false
frontend=false
devcontainer=false
if [[ "${1:-}" == --all ]]; then
  backend=true
  frontend=true
  devcontainer=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--all] < changed-paths.nul" >&2
  exit 64
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/*|scripts/verify.sh) backend=true; frontend=true; devcontainer=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*) ;;
      web/*) frontend=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|scripts/*|deploy/*) backend=true ;;
      *) backend=true; frontend=true ;;
    esac
  done
fi
printf 'backend=%s\nfrontend=%s\ndevcontainer=%s\n' "$backend" "$frontend" "$devcontainer"
