import { z } from "../../shared/schema";
import { request } from "../../shared/management";
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
        displayName: z.string().nullish(),
        principal: z.string().nullish(),
        model: z.string().nullish(),
        mode: z.string(),
        reasoningEffort: z.string().nullish(),
        requestMetadataRecorded: z.boolean().nullish(),
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
const keySummary = z
  .object({
    timezone: z.literal("UTC"),
    startUnixSeconds: count,
    endUnixSeconds: count,
    keys: z
      .array(
        z
          .object({
            keyID: z.string(),
            displayName: z.string().nullish(),
            principal: z.string().nullish(),
            pending: count,
            admitted: count,
            inFlight: count,
            succeeded: count,
            failed: count,
            cancelled: count,
          })
          .refine(
            (row) =>
              row.succeeded + row.failed + row.cancelled + row.inFlight <=
              row.admitted,
          ),
      )
      .max(256),
  })
  .refine(
    (report) =>
      report.startUnixSeconds % 86400 === 0 &&
      report.endUnixSeconds - report.startUnixSeconds === 86400,
  );
export async function fetchKeySummary(signal: AbortSignal) {
  return keySummary.parse(await request("/api/usage/keys", { signal })).keys;
}
export type KeySummary = z.infer<typeof keySummary>["keys"][number];
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
