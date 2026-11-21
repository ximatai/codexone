# CodexOne Rust gateway

Build the standalone executable from the repository root.

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml
rust/gateway/target/debug/codexone --help
```

The executable accepts the existing environment and private configuration file format. It supports `--check-config`, `--schema-version`, and offline `--migrate`. Startup with no identity exposes health checks and the management listener. With an unmanaged single identity and HTTP upstream transport, the data listener serves Responses JSON and SSE, independent compaction, and model discovery under both existing prefixes. The separate management listener serves health, system status, browser sessions, and the configured web bundle.

The SQLite startup adapter hands the locked database directly to the execution worker, which recovers abandoned intents before listeners serve traffic. Binding ownership is committed before IDs are exposed. Usage survives an interrupted write, and successful delivery is recorded when the terminal bytes reach the socket. A completed SSE event is flushed before the final marker. Shutdown stops admission, drains or closes connections within four seconds, then checkpoints and drains the writer. SQLite retains the WAL sidecars for offline read-only clients and closes the writer before releasing the instance lock.

## Verification

Build the compatible Swift reference, then use the shared process fixtures.

```sh
swift build --product codexone
python3 scripts/rust_compat/compare.py \
  --reference .build/debug/codexone \
  --candidate rust/gateway/target/debug/codexone
python3 scripts/verify_protocol.py --binary rust/gateway/target/debug/codexone
python3 scripts/verify_process.py --binary rust/gateway/target/debug/codexone
python3 scripts/rust_compat/readiness.py --binary rust/gateway/target/debug/codexone
python3 rust/config/tests/compare_swift.py \
  --reference .build/debug/codexone \
  --candidate rust/gateway/target/debug/codexone
```

## Compatibility scope

Managed Keys, subscription account pools, upstream and downstream WebSocket, native Images, zstd uploads, and encrypted HTTP body staging remain outside this executable. The Responses image tool uses the protocol crate's request and output handling, with SVG author rate attribution pending. Control endpoints, management data and mutations, live management updates, online backup, and offline commands beyond migration also remain pending. The SPA asset and session routes are available while screens requiring those APIs are pending.

The Rust catalog currently omits execution-budget source metadata. Both readiness endpoints and the management system report check the writer's storage pressure and restore admission gates. Liveness remains process-only. Ingress uses a shared body byte budget with immediate capacity rejection. Swift-specific diagnostic output and pre-admission ledger diagnostics remain pending. Performance, Linux deployment, and live provider behavior require separate validation.
