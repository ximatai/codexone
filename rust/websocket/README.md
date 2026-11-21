# CodexOne Responses WebSocket transport

The crate provides native downstream Responses WebSocket sessions and a fresh upstream WebSocket per bridged HTTP turn. Both accept caller-owned authorization and execution context. The crate exposes lifecycle and processing evidence independently from downstream delivery so a failed write can preserve evidence already observed.

## Native WebSocket

Call `upgrade_response` on an HTTP request to check the two Responses paths and build the provisional 101. Provide any HTTP upgrade error through the HTTP adapter's JSON error writer. Apply local Key authorization, turn-state header validation, and connection admission before returning 101. Pass the upgraded byte stream, including any HTTP read-ahead bytes, to `downstream_socket` and then `serve_native`.

Implement `NativeApplication` to apply current authorization, choose the initial identity, and persist admission before connecting or dispatching the first turn. The owner supplies `PreparedCreate` using `parse_create` and `native_frame`, with application-owned policy, tool continuity and verified state handling. Later turns receive the original identity. The session consumes one provider connection until it ends, with a new connection under the same identity allowed for a new independent create following a confirmed unprocessed size refusal. The transport never sends a refused create again. Named lanes are FIFO and have bounded concurrent admission and dispatch.

Use `evidence` to record provider evidence under the original attempt and `before_output` to apply binding barriers. `finish` transfers an owned attempt to the application's finalization path. Admission must handle cancellation of its future before returning the attempt. Closing downstream intake stops new admission and drains dispatched attempts within their original deadlines and a ten-second cap. The session emits at most one targeted interrupt per active response and awaits its socket tasks on exit.

## HTTP bridge

Build the frame with `create_frame`, then call `bridge_route` against the encoded payload and its continuation status. A WebSocket attempt receives an absolute execution deadline and fresh connector. The synchronous evidence callback receives correlated raw events. The async callback receives sanitized SSE event documents or the unwrapped terminal JSON document. Use that callback for the HTTP binding and output barrier. Write SSE finish markers from the HTTP owner after execution finalization.

Only `BridgeRoute::Http` or `BridgeFailure::UnprocessedSizeRefusal { http_fallback: true }` permits size-related routing to HTTP. Use the original admitted account, authorization, deadline and request semantics through the HTTP upstream transport. Close 1009 after possible processing, unclassified disconnects, invalid events and expired deadlines preserve dispatch uncertainty.

`UpstreamHandshake` keeps provider authorization separate from forwarded headers. Use `connect_direct` for direct connections and `connect_over` with the configured trusted dialer for explicit CONNECT proxy or custom roots. The latter expects an already verified TLS stream for `wss://`. Integration must apply the shared request-body budget and trusted header policy, connect the configured HTTP proxy, and implement durable evidence, binding and settlement. The default socket layer enforces per-frame and aggregated message byte caps and the peer queues enforce entry and byte caps. The Swift fragment-count limit and frame-header-time global body reservation still need ingress integration; the direct dialer uses Tokio TCP resolution without Swift's address racing.

## Verify

```sh
cargo test --locked --manifest-path rust/websocket/Cargo.toml
cargo clippy --locked --manifest-path rust/websocket/Cargo.toml --all-targets -- -D warnings
```
