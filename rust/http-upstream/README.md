# CodexOne HTTP upstream transport

`codexone-http-upstream` dispatches a caller-prepared HTTP/1.1 request over HTTP or HTTPS. Each call owns a fresh connection. An explicit trusted HTTP proxy uses CONNECT for both schemes. HTTPS verifies the provider hostname and certificate with the bundled Web PKI roots, or with an explicit root store from the caller.

Pass an absolute provider URI to `HttpUpstream::send`, along with request headers and an owned `RequestBody`. `RequestBody::bytes` slices fixed-length bytes without copying the original payload. `RequestBody::chunked` accepts a one-shot producer of at most 64 KiB per pull, including a caller-owned pre-encoded stream. Use `Response::collect` for a bounded JSON or error body. For streaming, take the status and headers, then pull payload bytes with `Response::next_chunk`. The transport preserves HTTP response bytes after transfer framing, including content encodings. The caller owns decoding and provider terminal-event validation.

`ExchangeOptions::deadline` accepts the absolute execution deadline from admission. The first-response allowance starts when the backpressured HTTP transport accepts the final fixed-length frame or polls a chunked producer to EOF. Local transport buffers can still contain data at this point. For a successful response, the first-response timer runs until the first nonempty body chunk in `BodyBytes` mode or the first effective event marked by the caller in `Explicit` mode. For SSE use `Explicit` and call `mark_response_progress` when event semantics warrant it. Early 2xx responses leave the upload active. Early non-2xx responses stop the producer and remain readable within the configured byte limit and total deadline.

Use `HttpUpstream::send_buffered` for a one-shot bounded exchange when its owner must end all HTTP I/O before publishing an outcome. The caller chooses whether to collect from the received status and headers. The API keeps those headers available even when body collection fails. This path drives the connection inline, so returning or dropping the future releases the driver immediately.

For streaming, dropping the pending dispatch or response cancels its connection task. Use the cancellation token to stop an exchange from another task, or `Response::close` to close and join the connection explicitly. Each invocation attempts one provider request. The caller owns provider-specific decisions such as 415 negotiation and accounting for a possibly executed request.

```sh
cargo test --locked --manifest-path rust/http-upstream/Cargo.toml
```
