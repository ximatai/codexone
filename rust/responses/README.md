# CodexOne Responses protocol

This crate implements the Responses HTTP JSON and SSE protocol boundary over `codexone-wire`. It can be built and tested independently.

```sh
cargo test --manifest-path rust/responses/Cargo.toml --locked
```

The transport checks the route, credentials, media type and body budget, then calls `Request::parse`. It uses the parsed fields for model policy and admission, and passes hard references to the execution coordinator for ownership verification. Affinity hints and turn state are routing inputs. Call `validate_contract` before admission and `into_upstream_document` to consume the request and prepare the ordered JSON body without cloning it. The final document's `stream` selects the generation upstream media type. The original request's `stream` selects SSE or JSON for the downstream. Independent compact uses JSON on both sides.

Validate the media type for successful upstream HTTP responses. Use `http_provider_failure` for non-200 responses, `observe_json` for bounded JSON bodies, and `ResponseStream::next_event` for SSE. Handle each observation before reading further. The execution coordinator records usage in revision order even when the delivery result fails. A successful delivery supplies binding facts, terminal state, and any outbound document. The coordinator applies its per-attempt binding limit and persists ownership before the transport submits output. Record completion after downstream submission succeeds. Stop upstream reading at terminal or error, and append `DONE_FRAME` only after successful SSE completion. EOF without terminal evidence remains indeterminate.

The Rust tests replay the Swift service's existing synthetic text fixture and check ordered request and response bytes, sparse SSE, foreign response isolation, explicit refusals, compact bindings, and image evidence. The protocol contract lives in [protocol.md](../../docs/reference/specs/protocol.md) and [usage.md](../../docs/reference/specs/usage.md).
