import type { AccountObservability } from "./observation-api";
export function quotaStale(
  value: AccountObservability,
  now = performance.now(),
) {
  return (
    value.quota.state === "stale" ||
    (now - value.receivedAt) / 1000 >= value.quota.freshForSeconds
  );
}
