# CodexOne native Images execution service

This crate assembles the native Images adapter, shared HTTP transport and
Swift-compatible v19 execution worker. Both native Images prefixes use the
same capacity pool and the selected image model's native provider endpoint.

## Data-plane integration

1. At startup, build one `ImageService` from the effective
   `ResponsesConfiguration` and the shared `HttpUpstream`. For static
   identities, `StaticImageTarget::from_config` reads the upstream token and
   builds the matching `StaticIdentity`. Open the shared `ExecutionService`
   with that policy and the configured business-day offset. Supply the same
   policy and pricing versions used by the other data-plane routes.
2. Route with `ImageRoute::from_path`. The gateway owns the ingress body
   lease, read deadlines and connection limits. It can call
   `StaticImageTarget::authenticate` before collecting a body.
   Call `start_static` with the bounded request, gateway request and attempt
   IDs, filtered client fingerprint headers, and disconnect token. Map
   `ServiceError::Execution` through the gateway's shared execution error
   mapping. `ServiceError::Image` retains the Images adapter's status, retry
   advice and error envelope. A cancelled client no longer needs a reply.
3. Keep the ingress lease and session until the response is finished. Pull
   `next` after each downstream write. A successful `Begin` includes safe
   provider headers, the gateway request ID, and a no-store directive. Forward
   each `Body` frame before pulling again. On error use its JSON and retry
   header before commitment, or its SSE replacement event after commitment.
   Preserve the safe provider image request ID from `response_headers` when
   building an error response. If needed, observe `upstream_head` internally
   before pulling the body.
4. Bound downstream writes by the disconnect token and `session.deadline()`.
   Call `finish` after the last downstream write and EOF, or after writing the
   adapter's terminal error. Use `cancel` on disconnect and `expire` on the
   delivery deadline. These calls close the transport, collect the final
   upstream evidence and hand off settlement to the bounded worker. Dropping
   the session also submits its last parsed evidence, including provisional
   counters when an SSE stream is dropped before cleanup. A request can have
   a failed or cancelled outcome and independently retain known usage. Missing
   evidence keeps its unknown exposure in the ledger.

## Pool integration

Authenticate the Key before parsing. Check the model selected by
`ImageService::parse` against the Key's effective native Images models before
invoking `start_authorized`. Its callback
runs after capacity acquisition and receives the selected model, bounded tier
and turn state, cancellation token, and absolute execution deadline. Select
the provider account, atomically recheck permissions and commit the intent
through the pool's durable admission command, then return the lease, account
base URI and service-owned authentication headers as `ImageDispatch`.
Credential refresh, pool routing, shared fingerprint headers and account
observations belong to their existing owners. The Images service makes one
upstream attempt per admitted request.

## Verification

```sh
cargo test --locked --manifest-path rust/image-service/Cargo.toml
```

The standalone integration tests load a private synthetic identity config,
create an isolated v19 SQLite database, and send requests to ephemeral
loopback listeners. They cover the static data-plane entry point and ledger
handoff. A gateway socket, managed account selection, and a live subscription
are outside this suite.
