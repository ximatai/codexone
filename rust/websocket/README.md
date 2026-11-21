# CodexOne Responses WebSocket transport

The crate provides native downstream Responses WebSocket sessions and a fresh upstream WebSocket per bridged HTTP turn. Both accept caller-owned authorization and execution context. The crate exposes lifecycle and processing evidence independently from downstream delivery so a failed write can preserve evidence already observed.

## Native WebSocket

Call `upgrade_response` on an HTTP request to check the two Responses paths and build the provisional 101. Provide any HTTP upgrade error through the HTTP adapter's JSON error writer. Apply local Key authorization, turn-state header validation, and connection admission before returning 101. Pass the upgraded byte stream, including any HTTP read-ahead bytes, and the data service's shared `Arc<dyn IngressBudget>` to `downstream_socket`. Pass the result and a shared application handle to `serve_native`.

The native reader parses mask, opcode, length and fragmentation headers before buffering. It waits at most five seconds for an initial service reservation, with bounded transport read-ahead during a wait. Continuations grow the existing lease without waiting. The admitted message retains that lease through queueing and execution. A 64 MiB message or 1024 fragments is allowed. The reader reports one 413 for a larger message or one 503 for exhausted capacity, drops the lease and discards the remainder in fixed-size chunks before parsing the next message. Valid control frames can interleave with fragmented and discarded messages. EOF, invalid framing and owner cancellation release partial, queued and active leases through their owners.

Implement `NativeApplication` to apply current authorization, choose the initial identity, and persist admission before connecting or dispatching the first turn. The owner supplies `PreparedCreate` using `parse_create` and `native_frame`, with application-owned policy, tool continuity and verified state handling. Later turns receive the original identity. The session consumes one provider connection until it ends, with a new connection under the same identity allowed for a new independent create following a confirmed unprocessed size refusal. The transport never sends a refused create again. Named lanes are FIFO and have bounded concurrent admission and dispatch.

Use `evidence` to synchronously record or hand off provider evidence under the original attempt. The single provider reader validates turn ownership and hands off evidence before queueing delivery, even while a different lane is suspended in `before_output` or its downstream write. Apply binding barriers in `before_output` and finalize through `finish`, which transfers the attempt once after its evidence registration has been removed. Admission must handle cancellation of its future before returning the attempt. Closing downstream intake stops new admission and drains dispatched attempts within their original deadlines and a ten-second cap. The session emits at most one targeted interrupt per active response and awaits its socket tasks on exit.

## HTTP bridge

Build the frame with `create_frame`, then call `bridge_route` against the encoded payload and its continuation status. A WebSocket attempt receives an absolute execution deadline and fresh connector. The synchronous evidence callback receives correlated raw events. The async callback receives sanitized SSE event documents or the unwrapped terminal JSON document. Use that callback for the HTTP binding and output barrier. Write SSE finish markers from the HTTP owner after execution finalization.

Only `BridgeRoute::Http` or `BridgeFailure::UnprocessedSizeRefusal { http_fallback: true }` permits size-related routing to HTTP. Use the original admitted account, authorization, deadline and request semantics through the HTTP upstream transport. Close 1009 after possible processing, unclassified disconnects, invalid events and expired deadlines preserve dispatch uncertainty.

`UpstreamHandshake` keeps provider authorization separate from forwarded headers. Use `connect_direct` for direct connections and `connect_over` with the configured trusted dialer for explicit CONNECT proxy or custom roots. The latter expects an already verified TLS stream for `wss://`. Integration supplies the shared request-body budget and trusted header policy, connects the configured HTTP proxy, and implements durable evidence, binding and settlement. The direct dialer uses Tokio TCP resolution without Swift's address racing.

## Verify

```sh
cargo test --locked --manifest-path rust/websocket/Cargo.toml
cargo clippy --locked --manifest-path rust/websocket/Cargo.toml --all-targets -- -D warnings
```
