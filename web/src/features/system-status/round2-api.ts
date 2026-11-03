import { readBusinessDay } from "../../shared/business-day";
import { z } from "../../shared/schema";
import { request } from "../../shared/management";
const count = z.number().int().nonnegative().safe();
const metric = z
  .string()
  .regex(/^(0|[1-9][0-9]{0,18})$/)
  .refine(
    (value) => /^[0-9]+$/.test(value) && BigInt(value) <= 9223372036854775807n,
  )
  .nullable();
const metrics = z.object({
  inputTokens: metric,
  cachedTokens: metric,
  outputTokens: metric,
  images: metric,
  estimatedMicros: metric,
});
const daily = z.object({
  timezone: z.string(),
  businessDay: z
    .object({
      offsetMinutes: z
        .number()
        .int()
        .min(-720)
        .max(840)
        .refine((v) => v % 60 === 0),
    })
    .default({ offsetMinutes: 0 }),
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
  const report = daily.parse(
    await request("/api/usage/daily?days=7", { signal }),
  );
  readBusinessDay(report);
  if (
    report.buckets.some(
      (bucket, i) =>
        (bucket.atUnixSeconds + report.businessDay.offsetMinutes * 60) %
          86400 !==
          0 ||
        (i > 0 &&
          bucket.atUnixSeconds - report.buckets[i - 1].atUnixSeconds !== 86400),
    )
  )
    throw new Error("Invalid daily buckets");
  return report;
}
export async function fetchInFlight(signal: AbortSignal) {
  return flight.parse(await request("/api/usage/in-flight", { signal })).rows;
}
const keySummary = z
  .object({
    timezone: z.string(),
    businessDay: z
      .object({
        offsetMinutes: z
          .number()
          .int()
          .min(-720)
          .max(840)
          .refine((v) => v % 60 === 0),
      })
      .default({ offsetMinutes: 0 }),
    startUnixSeconds: count,
    endUnixSeconds: count,
    keys: z
      .array(
        z
          .object({
            keyID: z.string(),
            enabled: z.boolean().optional(),
            tokens: metric.optional(),
            tokenUsageIncomplete: z.boolean().optional(),
            inputTokens: metric.optional(),
            cachedTokens: metric.optional(),
            cacheUsageIncomplete: z.boolean().optional(),
            lastUsedAtUnixSeconds: count.nullish(),
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
                row.admitted &&
              (row.inputTokens == null ||
                row.cachedTokens == null ||
                BigInt(row.cachedTokens) <= BigInt(row.inputTokens)),
          ),
      )
      .max(256),
  })
  .refine(
    (report) =>
      (report.startUnixSeconds + readBusinessDay(report).offsetMinutes * 60) %
        86400 ===
        0 && report.endUnixSeconds - report.startUnixSeconds === 86400,
  );
export async function fetchKeySummary(signal: AbortSignal) {
  const report = keySummary.parse(
    await request("/api/usage/keys?includeArchived=false", { signal }),
  );
  return report;
}
export type KeySummaryReport = z.infer<typeof keySummary>;
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
