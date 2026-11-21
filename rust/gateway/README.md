# CodexOne Rust gateway

Build the standalone executable from the repository root.

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml
rust/gateway/target/debug/codexone --help
```

The executable accepts the existing environment and private configuration file format. It supports `--check-config`, `--schema-version`, offline `--migrate`, and the [maintenance CLI](../maintenance/README.md). Startup with no identity exposes health checks and the management listener. With an unmanaged single identity or a subscription account pool using HTTP upstream transport, the data listener serves Responses JSON and SSE, independent compaction, and model discovery under both existing prefixes. The static identity also serves native Images. The management listener serves health, system status, browser sessions, and the configured web bundle. With an administrator credential and a database it also serves managed Key operations. A configured master key enables account management, OAuth, refresh, and passive quota observation.

The SQLite startup adapter hands the locked database directly to the execution worker, which recovers abandoned intents before listeners serve traffic. Binding ownership is committed before IDs are exposed. Usage survives an interrupted write, and successful delivery is recorded when the terminal bytes reach the socket. A completed SSE event is flushed before the final marker. Shutdown stops admission, drains or closes connections within four seconds, then checkpoints and drains the writer. SQLite retains the WAL sidecars for offline read-only clients and closes the writer before releasing the instance lock.

The pool authenticates the managed Key, resolves continuation ownership, prepares account credentials through the identity runtime, and verifies account state, Key policy, and capacity again when recording the durable intent. The production provider origin is fixed. Each admitted execution makes one upstream attempt. Startup recovers unresolved refresh intents in the same transaction as the execution ledger. Runtime shutdown joins authorization, refresh, and quota observation before closing the shared writer.

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
python3 scripts/verify_process.py --binary rust/gateway/target/debug/codexone
python3 scripts/rust_compat/readiness.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_pool_config.py --binary rust/gateway/target/debug/codexone
cargo test --locked --manifest-path rust/gateway/Cargo.toml managed_process
python3 rust/config/tests/compare_swift.py \
  --reference .build/debug/codexone \
  --candidate rust/gateway/target/debug/codexone
```

## Compatibility scope

Single-identity configuration with managed Keys, upstream and downstream WebSocket, zstd uploads, and encrypted HTTP body staging remain outside this executable. The Responses image tool uses the protocol crate's request and output handling, with SVG author rate attribution pending. Account force-stop, live execution counts, live catalog management, quota automation, usage reporting, online backup also remain pending.

The Rust catalog currently omits execution-budget source metadata. Both readiness endpoints and the management system report check the writer's storage pressure and restore admission gates. Pool readiness also checks for an enabled account with a locally verifiable credential and a model available to that account. Liveness remains process-only. Ingress uses a shared body byte budget with immediate capacity rejection. Swift-specific diagnostic output and pre-admission ledger diagnostics remain pending. The process test uses a private synthetic v19 database and loopback provider. Performance, Linux deployment, and live provider behavior require separate validation.
