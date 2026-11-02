# Verification

Record the actual validation of managed Key Token limits.

## Platform and results

2026-11-02, macOS arm64, Swift 6.4, Node 24.15 and Chrome. Backend production build passed. Full Swift run passed: Core 66, Runtime 66, end-to-end 6 and adapters 234 tests (372 total). Added actual SQLite cache-counting, threshold, retained totals, partial lower-bound, restart and UTC-day tests.

Real loopback HTTP and WebSocket verify_keys.py passed, including threshold rejection, rotation/restart preserving usage, exact Token/active metadata, old-field rejection, invalid/missing values and authentication. Offline import verification passed with new policy shape and HTTP/WS activation.

Frontend build/typecheck and 205 unit tests passed. Four existing Key browser flows passed; two new 1920/390-width tests passed, including real sequential decimal typing, unit conversion and exact two-field saved payload. Synthetic native-CSP demos with 10/20 requests passed at wide/narrow sizes, including drafts and confirmation cancellation, and screenshots were inspected.

## Rollback clarification

2026-11-02, macOS arm64 and Swift 6.4: checked the persisted two-field encoder against the pre-PR five-field decoder. A temporary offline probe using the unchanged decoder from main accepted a synthetic old policy and rejected both numeric and null tokens/active policies with missing requests. This confirms a format incompatibility, not an old version silently omitting Token enforcement. It does not constitute an old-binary startup or snapshot-restore acceptance test.

Updated the proposal, operator rollback guides and control-plane spec to prohibit direct original-database rollback after Token-policy writes. No downgrade converter or transitional configuration was added. Preserve the current verified full bundle; prefer a forward fix, or use a verified compatible pre-upgrade bundle in a new empty target with the existing reconciliation and maintenance gates. Documentation/link and diff checks passed. No application code or production state changed; backend/browser suites were not rerun for this documentation-only clarification.

## CI script corrections

2026-11-02: Linux PR CI passed docs, frontend, backend build and script shards 1/4 and 4/4, but exposed an old unresolved field in the Images fixture and a provider-event read inheriting the settlement handshake's 1-second socket timeout. Removed the obsolete Images field; separated the short handshake deadline from the normal 5-second event read, without retrying creates or changing connection-capacity/settlement deadline assertions. Also updated the cutback fixture's old request/money policy to an explicitly granted eight-Token policy: unknown first, then known usage exhausts the grant, with old baseline and new settled/unknown evidence still audited separately. No request/money-to-Token conversion is claimed.

macOS loopback verify_images.py passed for HTTP and WebSocket, verify_migration_cutback.py passed, and verify_client_protocol.py passed before and after the read-timeout correction, including cancellation, no replay, resource release and the shorter original execution deadline. Documentation and shard-ownership checks passed. Full Linux acceptance remains gated on the rerun of the PR workflow.

## Limits

Initial local verification did not include Linux/container or a real provider/client; Linux PR CI progress is recorded above and must be assessed from the final workflow result. Node is below the declared version. Full backend shard script collection was not rerun; relevant Key and import socket verifications were run. Existing Token counts are observations, not a hard ceiling; incomplete usage remains a lower bound. No production service was modified.

## 相关文档

[Proposal](proposal.md) - [Tasks](tasks.md)
