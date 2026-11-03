import type {
  DailyBucket,
  KeySummary,
} from "../src/features/system-status/round2-api";
export function dailyReport(buckets: DailyBucket[]) {
  return {
    timezone: "UTC",
    businessDay: { offsetMinutes: 0 },
    days: buckets.length,
    buckets,
  };
}
export function keyReport(keys: KeySummary[]) {
  return {
    timezone: "UTC",
    businessDay: { offsetMinutes: 0 },
    startUnixSeconds: 86400,
    endUnixSeconds: 172800,
    keys,
  };
}
