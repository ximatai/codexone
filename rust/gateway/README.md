# CodexOne Rust gateway

Build the standalone executable from the repository root.

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml
rust/gateway/target/debug/codexone --help
```

The executable accepts the existing environment and private configuration file format. It supports `--check-config`, `--schema-version`, offline `--migrate`, and the [maintenance CLI](../maintenance/README.md). Startup with no identity exposes health checks and the management listener. A single identity with either Key mode or a subscription account pool can serve Responses JSON and SSE, independent compaction, model discovery, and native Images generation and editing under `/v1` and `/backend-api/codex`. Selecting WebSocket upstream enables native Responses WebSocket and HTTP JSON/SSE bridging. Independent compaction and native Images use HTTP. The management listener serves health, system status, browser sessions, usage and storage reporting, live overview, and the configured web bundle. With an administrator credential and a database it also serves managed Key operations. A configured master key enables account management, OAuth, refresh, and passive quota observation.

The SQLite startup adapter hands the locked database directly to the execution worker, which recovers abandoned intents before listeners serve traffic. Binding ownership is committed before IDs are exposed. Usage survives an interrupted write, and successful delivery is recorded when the terminal bytes reach the socket. A completed SSE event is flushed before the final marker. Shutdown stops admission, drains or closes connections within four seconds, then checkpoints and drains the writer. SQLite retains the WAL sidecars for offline read-only clients and closes the writer before releasing the instance lock.

The pool authenticates the managed Key, resolves continuation ownership, prepares account credentials through the identity runtime, and verifies account state, Key policy, and capacity again when recording the durable intent. The production provider origin is fixed. Every Responses turn uses one durable execution. An independent bridged turn may use HTTP in the same execution after an oversized preflight or an explicit 1009 before possible processing. Native WebSocket fixes the provider account at the first admitted create and rechecks Key and account policy for later turns. Operators can inspect live per-account execution counts and force-stop a disabled account's current requests and fixed WebSocket connections. A force-stopped request preserves observed usage and leaves unresolved upstream execution in the ledger when evidence is incomplete. Startup recovers unresolved refresh intents in the same transaction as the execution ledger. Quota priming uses the configured HTTP or WebSocket transport and retains its durable window barrier across restarts. Runtime shutdown joins authorization, refresh, quota jobs, and quota observation before closing the shared writer.

Responses HTTP applies the configured zstd threshold to the final subscription request bytes. The data service reserves four compression workspaces and runs up to two 64 KiB steps in parallel. Enabling `CODEXONE_HTTP_BODY_STAGING=on` gives authenticated, known-length Responses uploads above 8 MiB a separate 192 MiB disk budget. AES-GCM records use anonymous files and an independent key per file. The gateway reclaims the shared memory reservation after it stages the final encoded request. A compressed HTTP upload refused with 415 can resend plaintext once within the same admission and deadline. The HTTP path after an allowed WebSocket size fallback uses this same upload handling.

## Verification

The native Images delivery check runs the Rust executable with a synthetic loopback provider and a temporary SQLite database. It verifies that a TCP reset and an absolute write timeout produce distinct outcomes while preserving usage and releasing the single image permit.

```sh
python3 scripts/rust_compat/image_delivery.py --binary rust/gateway/target/debug/codexone
```

Build the compatible Swift reference for the cross-backend comparisons.

```sh
swift build --product codexone
python3 scripts/rust_compat/compare.py \
  --reference .build/debug/codexone \
  --candidate rust/gateway/target/debug/codexone
python3 scripts/verify_protocol.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_control.py --binary rust/gateway/target/debug/codexone
cargo build --locked --release --manifest-path rust/gateway/Cargo.toml
python3 scripts/verify_upstream_zstd.py --binary rust/gateway/target/release/codexone
python3 scripts/verify_process.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_images.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_websocket.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_upstream_ws_body_limit.py --binary rust/gateway/target/debug/codexone
python3 scripts/rust_compat/readiness.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_pool_config.py --binary rust/gateway/target/debug/codexone
cargo test --locked --manifest-path rust/gateway/Cargo.toml managed_process
python3 rust/config/tests/compare_swift.py \
  --reference .build/debug/codexone \
  --candidate rust/gateway/target/debug/codexone
```

## Compatibility scope

The Responses image tool uses the protocol crate's request and output handling, with SVG author rate attribution pending. Subscription pools use the committed model directory for model listings, Key options, HTTP, WebSocket, and quota priming. Each admitted execution retains its captured rates through settlement. Desktop auxiliary controls share the pool’s credential health and keep upstream overload cooldowns scoped to the selected account and endpoint. The management listener serves usage reports, live overview with account and attention sources, and runtime storage observations.

Both readiness endpoints and the management system report check the writer's storage pressure and restore admission gates. Pool readiness also checks for an enabled account with a locally verifiable credential and a model available to that account. Liveness remains process-only. Ingress shares a 64 MiB body pool with 8 MiB of small-request headroom. Up to four requests can wait five seconds for an initial reservation. Partial uploads grow their reservations immediately. The process tests use private synthetic v19 databases and loopback providers. Swift-specific private diagnostics and address-candidate racing remain pending. Performance, Linux deployment, and live provider behavior require separate validation.

When configured, online backups run after an initial ten-minute delay and again 24 hours after each round completes.
