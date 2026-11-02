# Verification

Record the actual validation of managed Key Token limits.

## Platform and results

2026-11-02, macOS arm64, Swift 6.4, Node 24.15 and Chrome. Backend production build passed. Full Swift run passed: Core 66, Runtime 66, end-to-end 6 and adapters 234 tests (372 total). Added actual SQLite cache-counting, threshold, retained totals, partial lower-bound, restart and UTC-day tests.

Real loopback HTTP and WebSocket verify_keys.py passed, including threshold rejection, rotation/restart preserving usage, exact Token/active metadata, old-field rejection, invalid/missing values and authentication. Offline import verification passed with new policy shape and HTTP/WS activation.

Frontend build/typecheck and 205 unit tests passed. Four existing Key browser flows passed; two new 1920/390-width tests passed, including real sequential decimal typing, unit conversion and exact two-field saved payload. Synthetic native-CSP demos with 10/20 requests passed at wide/narrow sizes, including drafts and confirmation cancellation, and screenshots were inspected.

## Limits

No Linux/container or real provider/client verification was performed. Node is below the declared version. Full backend shard script collection was not rerun; relevant Key and import socket verifications were run. Existing Token counts are observations, not a hard ceiling; incomplete usage remains a lower bound. No production service was modified.

## 相关文档

[Proposal](proposal.md) - [Tasks](tasks.md)
