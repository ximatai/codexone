#!/usr/bin/env bash
# Runs a Codex executor in the workspace-write sandbox with the grants this
# repository's builds need. With --browser, Chrome runs outside the sandbox
# (seatbelt denies its Mach registration) and tests connect to it.
# Usage: scripts/codex_executor.sh WORKTREE BRIEF LOG [--browser]
set -euo pipefail
[[ $# -ge 3 ]] || { echo "Usage: $0 WORKTREE BRIEF LOG [--browser]" >&2; exit 64; }
worktree=$(cd "$1" && pwd)
brief=$2
log=$3
common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)
cache=$(getconf DARWIN_USER_CACHE_DIR)
writable=("$common" "$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/org.swift.swiftpm" "$HOME/.npm" "${cache}clang")
grants=()
for dir in "${writable[@]}"; do
  mkdir -p "$dir"
  grants+=(--add-dir "$dir")
done

server=""
cleanup() { [[ -n $server ]] && kill "$server" 2>/dev/null || true; }
trap cleanup EXIT
if [[ ${4:-} == --browser ]]; then
  endpoint_file=$(mktemp)
  (cd "$worktree/web" && exec node scripts/browser-server.mjs) >"$endpoint_file" &
  server=$!
  for _ in $(seq 50); do [[ -s $endpoint_file ]] && break; sleep 0.2; done
  [[ -s $endpoint_file ]] || { echo "Browser server did not start" >&2; exit 1; }
  export PW_TEST_CONNECT_WS_ENDPOINT
  PW_TEST_CONNECT_WS_ENDPOINT=$(head -1 "$endpoint_file")
  rm -f "$endpoint_file"
fi

export CODEXONE_BUILD_JOBS=${CODEXONE_BUILD_JOBS:-12}
export CODEXONE_SWIFTPM_DISABLE_SANDBOX=1
export PYTHONDONTWRITEBYTECODE=1
codex exec -m "${CODEX_EXECUTOR_MODEL:-gpt-6.1-sol}" -c model_reasoning_effort='"low"' \
  -s workspace-write -c sandbox_workspace_write.network_access=true \
  -C "$worktree" "${grants[@]}" "$(cat "$brief")" </dev/null >"$log" 2>&1
