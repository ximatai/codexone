# CodexOne configuration

`RuntimeConfiguration` parses the process environment or a supplied map.
`Configuration::load` validates local files and returns the settings for service
assembly. The loader performs synchronous metadata checks and bounded reads. Call
it before starting the services. It returns errors with fixed, redacted messages.

The product executable can dispatch `ConfigCommand::parse` before startup.
Pass the storage adapter's `SCHEMA_VERSION` to `ConfigCommand::run`; the example
uses the pinned Swift version for standalone testing.

From the repository root, compare the example against the [archived Swift executable](../../scripts/rust_compat/README.md):

```sh
cargo test --locked --manifest-path rust/config/Cargo.toml
cargo build --locked --manifest-path rust/config/Cargo.toml --example config_cli
python3 rust/config/tests/compare_swift.py \
  --reference "$SWIFT_BASELINE/.build/debug/codexone" \
  --candidate rust/config/target/debug/examples/config_cli
```

The comparison uses isolated synthetic files and an ephemeral loopback listener.
It compares exit status and output bytes, checks the fixture tree after each
invocation, and detects any connection to the synthetic upstream.
