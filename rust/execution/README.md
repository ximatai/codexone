# CodexOne execution

An independent crate for durable single-account execution on an existing Swift
v19 SQLite ledger. `ExecutionService::open` takes the database path and configured
managed account ID, obtains the instance lock through `codexone-storage`, and
marks old dispatch intents unknown before returning. It uses the Swift
settlement-reserve sidecar and requires physical reserve space for admission.

## Runtime integration

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
3. Call `observe` for trusted cumulative usage before forwarding any associated
   output. Compute estimated micros with the rates captured at admission by
   the provider/runtime adapter. Supply complete zero evidence only for
   provider observations that prove it. Call `bind` for the referenceable
   object IDs before exposing each output. Stop exposing output on a binding
   error or interruption.
4. Consume the lease with `finish` or `cancel`. Dropping it also transfers
   finalization with the last captured usage. Handoff returns after enqueue.
   `reconcile` applies trusted late evidence by attempt and revision.
5. Schedule `expire_unknown` and `maintain_storage` from the runtime. During
   shutdown stop admitting new work, close or drain transport tasks, then await
   `shutdown` within the runtime deadline. Use `force_shutdown` to close the
   queue after the deadline. Incomplete intents will be recovered at the next
   open. Watch `status` for fatal writer or finalizer failure; the accepting
   status describes queue liveness, and each admission also checks storage and
   restore gates.

The async API uses one SQLite worker thread. It has 16 regular slots and at
most 16 finalization tickets across active leases, queued settlements, and the
current settlement. Request bodies, upstream responses, and transport buffers
belong to the caller. The crate covers managed-Key admission for generation,
warmup, compact and Images. The application integration still owns provider
routing and pacing, credential refresh, quota priming, detail retention and
rollups, pricing inputs, and transport-specific continuation and retry rules.

## Verification

Run `cargo test --locked --manifest-path rust/execution/Cargo.toml` from the repo
root. The tests create isolated temporary databases using the Swift baseline's
v19 initialization SQL. They inject transactional admission, binding, and
settlement failures, and exercise cancellation, recovery, restore freeze,
ownership, quotas, and cumulative evidence compaction.
