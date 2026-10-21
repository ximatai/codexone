# Real Codex compatibility experiment

This laboratory adds an opt-in Responses relay. It is not a production gateway.

## Acceptance requirements

- Existing fixture-only mode MUST retain its loopback upstream restriction and remain credential-free.
- Real-upstream mode MUST require an explicit base URL, upstream token and separate local bearer token. The listener MUST remain bound to loopback. Non-loopback upstreams MUST use HTTPS; URLs with userinfo, query or fragment MUST be rejected.
- The relay MUST expose POST `/v1/responses` , POST `/v1/responses/compact` and POST `/v1/images/generations` on the NIO HTTP port, and GET `/v1/responses` for WebSocket upgrades on the Vapor port. A disabled relay MUST NOT forward these requests.
- Client credentials MUST NOT reach the upstream. Only the configured upstream credentials and selected protocol headers may be forwarded. Request bodies and response events MUST remain unmodified. Upstream redirects MUST NOT be followed.
- Unauthorized, unknown and oversized HTTP requests MUST produce explicit error responses. Upstream status and supported protocol headers MUST be preserved.
- The real CLI experiment MUST use a temporary Codex home and disposable work directory. It MUST NOT change existing Codex configuration or Ali services. It MUST fail visibly on unsuccessful CLI runs, missing expected output or missing protocol evidence.
- Reports MUST distinguish actual CLI/live upstream runs from fixture coverage, identify transport and client version, and omit credentials, raw prompts and response bodies from publishable evidence.

## Initial scope

HTTP and WebSocket use separate ports. One HTTP request per connection, 20 MiB HTTP bodies, 2 MiB aggregated WebSocket messages and 4 MiB/1024-message queues remain lab limits. No retries, OAuth refresh, account pooling, durable metering or production deployment are implemented here.

Live validation uses synthetic prompts and a single explicitly selected existing account. It may consume that account's normal model allowance. CI runs credential-free contract tests only; live runs stay local.


The image endpoint currently forwards the native Images request unchanged. It does not translate Images requests into Responses image tools. The test client declares `x-openai-actor-authorization` with a non-empty laboratory identifier to expose Codex 0.163.0's native image extension. The relay strips this client declaration before the upstream hop; it is not an upstream credential.

Live `--auto-compact` MUST explicitly declare provider remote compaction V2, lower the token threshold, observe a persisted compaction record, and verify marker-preserving continuation. A legacy compact HTTP 404 MUST remain visible as a failed diagnostic rather than be treated as successful compaction.
