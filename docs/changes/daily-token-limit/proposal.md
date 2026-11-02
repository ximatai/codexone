# Daily Token limit

Implement the user-approved managed Key Token budget.

## Contract

User approved tokens plus active only, with Token/10K/1M unit switching. Count input (including cached) plus output, no duplicate cached addition. Native image tokens use provided image input/output. Missing usage stays unknown; cap gates new admissions by observed lower bound, never cancels admitted work or promises a hard ceiling. UTC admission day owns late usage.

## Implementation

Core policy and strict management API expose tokens/active; old request limits are not converted into tokens. SQLite admission sums attempts plus retained daily aggregates transactionally. No new database columns. Single-identity execution safety remains separate. Existing installations require explicit metadata repair before release.

## Acceptance and rollback

Verify SQLite threshold, cache, concurrency, UTC rollover, restart, missing evidence and retention; strict HTTP fields and browser unit conversion, unlimited, conflicts and narrow layout. Back up before repair. A schema-v11 database containing newly written tokens/active policies must not be opened by old five-field binaries: required legacy fields are missing, so Key reads and authentication fail rather than merely skipping Token enforcement. There is no in-place downgrade API or converter. Prefer a forward fix; if an old binary is required, preserve and verify the current full bundle, restore a verified pre-upgrade compatible bundle into a new empty directory, and complete missing-interval reconciliation, Key replacement, account authorization and maintenance gates. Without a compatible bundle, remain stopped. See the [rollback procedure](../../guide/key-governance.md#兼容回退前提). References: I12, U01/U03/U04, A10/A11.

## 相关文档

[Tasks](tasks.md) - [Usage spec](../../reference/specs/usage.md)
