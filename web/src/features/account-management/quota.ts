import type { AccountObservability } from "./observation-api";

export function quotaWindowLabel(seconds: number | null, fallback: string) {
  if (seconds === 18_000) return "5 小时额度";
  if (seconds === 604_800) return "每周额度";
  return seconds && seconds % 3600 === 0
    ? `${seconds / 3600} 小时额度`
    : fallback;
}

export function quotaStale(
  value: AccountObservability,
  now = performance.now(),
) {
  return (
    value.quota.state === "stale" ||
    (now - value.receivedAt) / 1000 >= value.quota.freshForSeconds
  );
}
