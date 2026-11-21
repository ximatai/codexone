# CodexOne execution

An independent crate for durable single-account execution on an existing Swift
v19 SQLite ledger. `ExecutionService::open` takes the database path and identity
options, obtains the instance lock through `codexone-storage`, and marks old
dispatch intents unknown before returning. It uses the Swift
settlement-reserve sidecar and requires physical reserve space for admission.

## Static identity

For a local single-identity config with `managedKeys` absent or false, build
`StaticIdentityConfig` from the validated config. Supply the decoded 32-byte
`keySHA256`, configured owner and exact upstream base URL, effective text
model IDs and image model IDs, and the policy and pricing versions and
reservation. Set `vision_input` when a configured text model allows vision.
Pass the same effective upstream access token as the provider adapter to
`StaticIdentity::new`, or `None` for a synthetic upstream without a token.
The constructor derives the Swift-compatible namespace and retains the scope
digest. Open with `Options::for_static_identity(policy)`.

Call `authenticate_static` with the Authorization headers, then pass the
returned proof to `admit_static` with the classified `StaticAdmissionRequest`.
Map a validated `previous_response_id` to an `ObjectBinding` of type
`response`. An open service accepts proofs issued by that service, and the
provider transport applies catalog reasoning and other request-specific
validation before admission. Static execution uses the same durable execution
lease, binding, usage and recovery commands as the managed flow. Static
admissions leave the managed Key and account tables empty and carry neither
a Key revision nor an account snapshot.

## Managed identity

Open with `Options::new(account_id)`.

1. Pass the Authorization headers to `authenticate`. Obtain the configured
   account's encrypted credential with `account_credential` and open it with
   `codexone-storage` using the returned account ID, namespace and credential
   version.
2. Classify operation requirements and continuation references from the
   validated request. Capture the account revision and credential expiry,
   policy and pricing versions, and an estimate in `AdmissionRequest`. The
   transport verifies connection affinity before setting the continuation flag.
   Call `admit` and then `Execution::begin_dispatch` immediately before the
   logical upstream operation. Admission commits the intent and verifies the
   current Key revision, account, model, reference ownership and limits.
## Execution lease and shutdown

1. Call `observe` for trusted cumulative usage before forwarding any associated
   output. Compute estimated micros with the rates captured at admission by
   the provider/runtime adapter. Supply complete zero evidence only for
   provider observations that prove it. Call `bind` for the referenceable
   object IDs before exposing each output. Stop exposing output on a binding
   error or interruption.
2. Consume the lease with `finish` or `cancel`. Dropping it also transfers
   finalization with the last captured usage. Handoff returns after enqueue.
   `reconcile` applies trusted late evidence by attempt and revision.
3. Schedule `expire_unknown` and `maintain_storage` from the runtime. During
   shutdown stop admitting new work, close or drain transport tasks, then await
   `shutdown` within the runtime deadline. Use `force_shutdown` to close the
   queue after the deadline. Incomplete intents will be recovered at the next
   open. Watch `status` for fatal writer or finalizer failure; the accepting
   status describes queue liveness, and each admission also checks storage and
   restore gates.

The async API uses one SQLite worker thread. It has 16 regular slots and at
most 16 finalization tickets across active leases, queued settlements, and the
current settlement. Request bodies, upstream responses, and transport buffers
belong to the caller. The crate covers managed and static admission for generation, warmup,
compact and Images. The application integration still owns provider
routing and pacing, credential refresh, quota priming, detail retention and
rollups, pricing inputs, and transport-specific continuation and retry rules.

## Verification

Run `cargo test --locked --manifest-path rust/execution/Cargo.toml` from the repo
root. The tests create isolated temporary databases using the Swift baseline's
v19 initialization SQL. They inject transactional admission, binding, and
settlement failures, and exercise cancellation, recovery, restore freeze,
ownership, quotas, and cumulative evidence compaction. The static tests use
empty governance tables and cover the first turn, restart with
`previous_response_id`, and settlement under the same scoped owner.
