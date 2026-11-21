# Account quota jobs

The workers implement the I21/I22 account-owned jobs against the Swift v19
ledger. Use the same `ExecutionService` writer, `Governance`, and
`IdentityRuntime` for management, observations, and jobs. Change the settings
through the supervisor methods with the current account revision. No schema
migration is required.

- Run `PrimingWorker::run` in one supervised task. Pass the current conversation
  model catalog to `PrimingSupervisor::new`. Implement `PrimingTransport` with
  the gateway's configured Responses transport. The lease has already acquired
  dispatch authority. Submit normal usage evidence through the lease, consume
  the provider response internally, and return its outcome after closing the
  exchange. Honor the supplied deadline and cancellation token.
- Run `ResetSupervisor::run` in another supervised task. Use its methods for
  manual resets so that scheduled and manual operations share four slots and
  the same per-account gate. For automatic reconciliation the scheduler retains
  only the original card's deadline and reuses its stored provider request ID.
- The identity runtime can publish successful observation hints through
  `set_observation_listener`. Call `PrimingSignals::observed_quota` on success
  and `ResetSupervisor::observed_credits` when a count is present. Capture the
  reset supervisor weakly so the callback does not own its own identity runtime.
- Authenticate and validate management requests at the existing admin boundary.
  The crate exports the A18/A19 input DTOs and safe response shapes. Mount
  `list_with_status`, `status`, `consume`, and the two `set_settings` commands
  behind that boundary.
- On shutdown signal `PrimingSignals::stop` and await
  `ResetSupervisor::shutdown`. Join both workers before closing identity and
  the execution writer. The writer finalizes admitted leases during shutdown
  and recovers unresolved priming audits before the next startup.

Run the focused contract tests with
`cargo test --locked --manifest-path rust/quota-jobs/Cargo.toml`.
The fixture seeds the Swift v19 schema, uses disposable loopback OAuth/quota
endpoints and a captured priming exchange, and never contacts a subscription.
