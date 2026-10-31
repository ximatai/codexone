import { z } from "../../shared/schema";
import { request } from "../../shared/management";
import {
  defaults,
  fetchUsage,
  usageParameters,
  parseUsage,
} from "../usage/api";
const count = z.number().int().nonnegative().safe();
const metric = z
  .string()
  .regex(/^(0|[1-9][0-9]{0,18})$/)
  .nullable();
const metrics = z.object({
  inputTokens: metric,
  cachedTokens: metric,
  outputTokens: metric,
  images: metric,
  estimatedMicros: metric,
});
const daily = z.object({
  timezone: z.literal("UTC"),
  days: z.number().int().min(1).max(31),
  buckets: z
    .array(
      z.object({
        atUnixSeconds: count,
        requests: count,
        succeeded: count,
        failed: count,
        cancelled: count,
        failures: z.record(z.string(), count),
        metrics,
      }),
    )
    .max(31),
});
const flight = z.object({
  rows: z
    .array(
      z.object({
        id: z.string(),
        keyID: z.string(),
        principal: z.string().nullish(),
        model: z.string().nullish(),
        mode: z.string(),
        accountID: z.string().nullable(),
        accountDisplayName: z.string().nullable().optional(),
        startedAtUnixSeconds: count.nullish(),
        elapsedSeconds: z.number().nonnegative().nullish(),
        hasFirstEvent: z.boolean().nullish(),
      }),
    )
    .max(200),
});
export type DailyBucket = z.infer<typeof daily>["buckets"][number];
export async function fetchDaily(signal: AbortSignal) {
  return daily.parse(await request("/api/usage/daily?days=7", { signal }))
    .buckets;
}
export async function fetchInFlight(signal: AbortSignal) {
  return flight.parse(await request("/api/usage/in-flight", { signal })).rows;
}
export async function fetchRecent(signal: AbortSignal) {
  // Page the bounded 31-day window until twenty finalized requests are found.
  const filters = {
    ...defaults(),
    start: new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10),
  };
  const rows: Awaited<ReturnType<typeof fetchUsage>>["rows"] = [];
  let cursor: string | null = null;
  for (let page = 0; page < 10; page++) {
    const parameters = usageParameters(filters, cursor);
    parameters.set("limit", "100");
    const report = parseUsage(
      await request("/api/usage?" + parameters, { signal }),
    );
    rows.push(
      ...report.rows.filter(
        (row) => row.kind === "admitted" && row.state !== "intent",
      ),
    );
    if (rows.length >= 20 || !report.nextCursor)
      return { rows: rows.slice(0, 20), truncated: false };
    cursor = report.nextCursor;
  }
  return { rows: rows.slice(0, 20), truncated: true };
}
export function tokenTotal(bucket: DailyBucket): number | null {
  const { inputTokens, outputTokens } = bucket.metrics;
  return inputTokens === null || outputTokens === null
    ? null
    : Number(BigInt(inputTokens) + BigInt(outputTokens));
}
export function change(
  current: number | null | undefined,
  previous: number | null | undefined,
) {
  if (current == null || previous == null) return "较昨日不可用";
  if (previous === 0) return current === 0 ? "较昨日持平" : "较昨日新增";
  const percent = ((current - previous) / previous) * 100;
  return `较昨日 ${percent >= 0 ? "+" : ""}${percent.toFixed(1)}%`;
}
export function pointChange(
  current: number | null | undefined,
  previous: number | null | undefined,
) {
  if (current == null || previous == null) return "较昨日不可用";
  const points = current - previous;
  if (Math.abs(points) < 0.05) return "较昨日持平";
  return `较昨日 ${points > 0 ? "+" : ""}${points.toFixed(1)} 个百分点`;
}
