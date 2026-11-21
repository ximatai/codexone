# Rust account pool

This crate implements generation routing for the Swift-compatible v19 ledger. The execution service owns the SQLite writer, transaction, execution tickets, Key policy and ledger lifecycle. The account pool takes prepared nonsecret snapshots and the transaction already opened by that service.

## Execution integration

1. Resolve hard object and connection affinity with `resolve_affinity` before credential preparation. Resolve recent soft history hints with `resolve_hint` before falling back to `SessionAffinity`. Supply a verified `TurnStateOwners` match as `Selection::required`. A turn-state match alone cannot resume a draining account.
2. Feed prepared candidates into `admit` on the execution writer's immediate transaction. `allows_account` checks the current model catalog and configured account pin. `check_key` checks the current managed Key, restore gate, duplicate attempt and applicable limits using the command's current business day. `insert_intent` writes the normal ledger admission using the selected candidate. The pool already rechecks snapshot, capacity, ownership and health and renews the selected bindings in the same transaction. The execution service commits before returning the lease and rolls back every error.
3. Translate a pacing `Wait` into an await outside the transaction, with the provisional ticket released. `PacingWaiters` provides a bounded monotonic timer. The request's cancellation and total deadline own the timer future. On wake, reacquire a ticket and repeat preparation and admission. Map `Cooldown` to the normal account-unavailable response with the supplied rounded `Retry-After`. Initiate `PacingWaiters::close` during service shutdown.
4. Keep one `Health` per writer. After the ledger's duplicate-outcome check, stage the first trusted terminal result using `Health::record` inside finalization. Pass wall-clock Unix microseconds to admission and finalization for precise pacing. Apply the returned update immediately after the transaction commits. Drop it on rollback. Keep the `health_models` table current and call `retain_models` after changing it. A restarted writer creates fresh `Health` and observes persisted deadlines.

Credential listing, decryption and refresh, configured model and Key authorization, outcome/status translation, connection retirement and force-stop, auxiliary dispatch, and the concrete intent/finalizer entry points belong to their existing owners. The focused tests use independent temporary v19 databases and synthetic fixtures.

```sh
cargo test --locked --manifest-path rust/account-pool/Cargo.toml
```
