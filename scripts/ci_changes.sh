#!/usr/bin/env bash
# Consume git diff --name-only -z (including both paths of renames via --no-renames).
set -euo pipefail
backend=false
frontend=false
devcontainer=false
if [[ "${1:-}" == --push && $# == 4 ]]; then
  paths=$(mktemp)
  trap 'rm -f "$paths"' EXIT
  if [[ "$2" != false || ! "$3" =~ ^[0-9a-f]{40}$ || ! "$4" =~ ^[0-9a-f]{40}$ ]] ||
    ! git merge-base --is-ancestor "$3" "$4" ||
    ! git diff --name-only -z --no-renames "$3" "$4" -- > "$paths"; then
    set -- --all
  else
    exec < "$paths"
    set --
  fi
fi
if [[ "${1:-}" == --all ]]; then
  backend=true
  frontend=true
  devcontainer=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--all | --push FORCED BEFORE AFTER] < changed-paths.nul" >&2
  exit 64
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/*|scripts/verify.sh|scripts/ci_changes.sh|scripts/check_ci.py|scripts/test_check_ci.py|scripts/backend_shards.*)
        backend=true; frontend=true; devcontainer=true ;;
      .devcontainer/*) devcontainer=true ;;
      *.md|docs/*|LICENSE*) ;;
      web/*) frontend=true ;;
      Sources/*|Tests/*|Package.swift|Package.resolved|scripts/*|deploy/*) backend=true ;;
      *) backend=true; frontend=true; devcontainer=true ;;
    esac
  done
fi
printf 'backend=%s\nfrontend=%s\ndevcontainer=%s\n' "$backend" "$frontend" "$devcontainer"
