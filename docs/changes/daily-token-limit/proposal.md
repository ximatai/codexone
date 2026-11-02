# Daily Token limit

Implement the user-approved managed Key Token budget.

## Contract

User approved tokens plus active only, with Token/10K/1M unit switching. Count input (including cached) plus output, no duplicate cached addition. Native image tokens use provided image input/output. Missing usage stays unknown; cap gates new admissions by observed lower bound, never cancels admitted work or promises a hard ceiling. UTC admission day owns late usage.

## Implementation

Core policy and strict management API expose tokens/active; old request limits are not converted into tokens. SQLite admission sums attempts plus retained daily aggregates transactionally. No new database columns. Single-identity execution safety remains separate. Existing installations require explicit metadata repair before release.

## Acceptance and rollback

Verify SQLite threshold, cache, concurrency, UTC rollover, restart, missing evidence and retention; strict HTTP fields and browser unit conversion, unlimited, conflicts and narrow layout. Back up before repair. Old binaries do not enforce Token caps and need explicit rollback configuration. References: I12, U01/U03/U04, A10/A11.

## 相关文档

[Tasks](tasks.md) - [Usage spec](../../reference/specs/usage.md)
