# CodexOne native Images adapter

`codexone-images` implements the native Images generation and edits contract for both data prefixes. It uses `codexone-wire` for ordered JSON and byte-preserving SSE framing, and `codexone-http-upstream` for a single HTTP attempt against the selected account.

## Data service integration

1. Match `ImageRoute::from_path` and authenticate the Key. Read the request under the shared ingress body budget and deadlines. Pass the original headers and bounded body to `ImageRequest::parse` along with the deployed model IDs and default. Use the parsed model, service tier and turn state in the existing authorization and routing logic. Verify the Key allows the selected image model.
2. Acquire a permit from the data service's shared `ImageCapacity` before creating an execution intent. Keep the permit through response delivery and execution cleanup. Timeout and cancellation before acquisition create no intent. The capacity lease and durable accounting have independent lifetimes.
3. After persisted admission, call `ImageExchange::start` with the selected account's base URI and service-owned authentication headers. Supply the shared client fingerprint policy's forwarded metadata, the selected image model rates and configured SVG author rates. Use the request's absolute execution deadline, the configured Images first-response allowance, and the shared progress timeout for both upload and response idle limits in `ExchangeOptions`. The transport starts the first-response allowance at its local upload completion boundary. Buffered JSON progresses on body bytes. SSE progresses on known completions and nonempty known previews.
4. Inspect `upstream_status` and `upstream_headers` for internal account observations. Pull `next` with downstream backpressure. On `ImageOutput::Begin`, commit its safe headers with the gateway's `x-request-id` and `cache-control: no-store`. Write each `ImageOutput::Body` and finish the downstream response at EOF. On failure before commit, use `ImageError::json`, its status and `retry_header`. After committing SSE, use `ImageError::sse` while the writer can still send. Preserve the safe image request ID from `response_headers` on error.
5. Cancel the exchange token on downstream disconnect. Call `close` to join any outstanding upstream connection task and get the final evidence. Map native counters into the existing Images usage fields, including the refusal proof flag, with zero internal host counters and native Images enabled. Persist the bounded service tier and measure first-event latency from the execution context using `first_event_at`. Keep validated usage independently of the failure or delivery outcome. Treat `invalid_legacy_result` as invalid provider output for the ledger even when the legacy edit response was a raw HTTP 200. Use the existing durable finalizer for settlement and unknown exposure. Dispatch at most once.

The tests use isolated loopback sockets and the repository's synthetic reference image fixtures.

```sh
cargo test --locked --manifest-path rust/images/Cargo.toml
```
