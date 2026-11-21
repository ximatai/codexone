# CodexOne Rust subscription identity runtime

The crate supplies the subscription OAuth callback, device-code and refresh provider, verified dispatch headers, and passive quota observation. Production authorizes against the fixed auth and data origins. An explicit loopback factory isolates the synthetic realm from production namespaces. The provider validates claims from trusted token responses and credentials opened from the gateway's sealed store.

Construct `IdentityRuntime` with the same `governance::Writer`, governance service, and keyring as the gateway. The runtime shares governance's refresh owner across the admin, dispatch, and periodic paths. Execute `governance::recover_refreshes` in the gateway's startup transaction before publishing readiness. Dispatch preparation returns sensitive headers and the account revision, credential version, and expiry for atomic admission rechecks.

Run `run_periodic` alongside the listeners. `observe_account` joins the same four-worker passive quota scheduler. The quota writer commits normalized snapshots, credit samples and cycle samples using the existing v19 schema. Quota failures retain the last success and have no effect on execution health. Call `shutdown` and join the periodic task before closing the writer. The buffered HTTP exchanges own their connections within the refresh, authorization or quota future. Cancelling one of those futures synchronously ends its HTTP driver. Identity shutdown also waits for active writer replies, including accepted reads whose caller cancelled. If the gateway runs the separate governance authorization owner, close it before draining the writer as well.

The gateway assembly owns execution cancellation, readiness, startup recovery, the management endpoints and wiring of observation into any reset-card or priming supervisors. Current verification uses synthetic tokens and an ephemeral SQLite database. Live provider and deployed gateway behavior require separate verification.

```sh
cargo test --locked --features test-support --manifest-path rust/identity-runtime/Cargo.toml
rust/identity-runtime/tests/verify-swift.sh
```

The test feature enables driver completion probes and a TLS fixture for the production auth and quota origins. The fixture checks one OAuth exchange, one refresh, and one quota observation through a loopback CONNECT proxy, with credentials confined to the TLS endpoint. The optional Swift check uses swiftc 6.4 to compile quota Codable types from the [fixed Swift archive](https://github.com/ximatai/codexone/tree/65624e4c45ee1f86560b7640abe42bec31a25f60), then round-trips the same synthetic record through both implementations. If a shallow clone lacks the commit, run `git fetch origin refs/heads/archive/swift-v0.26.53` first.
