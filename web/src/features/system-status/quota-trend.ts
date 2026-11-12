import { request } from "../../shared/management";
import { z } from "../../shared/schema";

const timestamp = z.number().int().positive().max(1_000_000_000_000);
const sample = z.tuple([timestamp, z.number().min(0).max(100)]);
const windowTrend = z.object({
  reset: timestamp,
  duration: z.number().int().positive().max(31_536_000),
  samples: z
    .array(sample)
    .max(289)
    .refine((items) =>
      items.every(
        ([at, remaining], i) =>
          i === 0 || (at > items[i - 1][0] && remaining <= items[i - 1][1]),
      ),
    ),
});
const accountTrend = z.object({
  primary: windowTrend.optional(),
  secondary: windowTrend.optional(),
});
export type QuotaSample = z.infer<typeof sample>;
export type QuotaHistory = z.infer<typeof windowTrend>;
export const referenceHours = [1, 8, 24] as const;
export type ReferenceHours = (typeof referenceHours)[number];
const maximumGap = 15 * 60;

export async function fetchQuotaTrend(accountID: string, signal: AbortSignal) {
  return accountTrend.parse(
    await request(
      `/api/accounts/${encodeURIComponent(accountID)}/quota-trend`,
      { signal },
    ),
  );
}

export function quotaSegments(samples: QuotaSample[]) {
  const segments: QuotaSample[][] = [];
  for (const point of samples) {
    const segment = segments.at(-1);
    if (!segment || point[0] - segment.at(-1)![0] > maximumGap)
      segments.push([point]);
    else segment.push(point);
  }
  return segments;
}

export function predictQuota(samples: QuotaSample[], hours: ReferenceHours) {
  const last = samples.at(-1);
  if (!last) return { state: "coverage" } as const;
  const period = hours * 3600;
  const cutoff = last[0] - period;
  const step = hours === 1 ? 300 : hours === 8 ? 900 : 3600;
  const points: QuotaSample[] = [];
  let covered = 0;
  let drop = 0;
  let changes = 0;
  let unobservedDrop = false;
  let tick = cutoff;
  for (let i = 1; i < samples.length; i++) {
    const [a, before] = samples[i - 1];
    const [b, after] = samples[i];
    if (b <= cutoff) continue;
    if (b - a > maximumGap) {
      // The change is real, but its timing cannot inform a fitted consumption rate.
      if (before > after) unobservedDrop = true;
      continue;
    }
    covered += b - Math.max(a, cutoff);
    if (a >= cutoff && before > after) {
      drop += before - after;
      changes++;
    }
    tick = Math.max(tick, cutoff + Math.ceil((a - cutoff) / step) * step);
    while (tick <= b) {
      points.push([
        tick - cutoff,
        before + ((after - before) * (tick - a)) / (b - a),
      ]);
      tick += step;
    }
  }
  if (covered < period / 2) return { state: "coverage" } as const;

  const fullCoverage = hours === 1 ? 3300 : (period * 2) / 3;
  if (
    unobservedDrop ||
    covered < fullCoverage ||
    points.length < Math.ceil(fullCoverage / step) ||
    changes < 3 ||
    drop < 1
  ) {
    if (drop < 1)
      return { state: covered < fullCoverage ? "coverage" : "signal" } as const;
    return {
      state: "coarse",
      anchor: last,
      rate: drop / covered,
      slow: Math.max(0, drop - 1) / covered,
      fast: (drop + 1) / covered,
    } as const;
  }

  const meanTime = points.reduce((sum, [at]) => sum + at, 0) / points.length;
  const meanRemaining =
    points.reduce((sum, [, remaining]) => sum + remaining, 0) / points.length;
  const variance = points.reduce((sum, [at]) => sum + (at - meanTime) ** 2, 0);
  const rate =
    -points.reduce(
      (sum, [at, remaining]) =>
        sum + (at - meanTime) * (remaining - meanRemaining),
      0,
    ) / variance;
  if (!(rate > 0)) return { state: "signal" } as const;
  const speeds = points
    .flatMap(([at, remaining], i) => {
      const later = points
        .slice(i + 1)
        .find(([next]) => next - at >= period / 2);
      return later ? [(remaining - later[1]) / (later[0] - at)] : [];
    })
    .sort((a, b) => a - b);
  return {
    state: "ready",
    anchor: last,
    rate,
    slow: Math.min(rate, speeds[Math.floor((speeds.length - 1) * 0.1)] ?? rate),
    fast: Math.max(rate, speeds[Math.ceil((speeds.length - 1) * 0.9)] ?? rate),
  } as const;
}
