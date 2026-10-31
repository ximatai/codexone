import { ManagementError, request } from "../../shared/management";
export interface UsageFilters {
  start: string;
  end: string;
  key: string;
  model: string;
  mode: string;
  failure: string;
  state: string;
  failedOnly: boolean;
  range?: "24h";
  window?: { start: number; end: number };
}
export interface Metrics {
  imageInputTextTokens?: string | null;
  imageInputImageTokens?: string | null;
  imageInputTokens?: string | null;
  imageOutputTokens?: string | null;
  inputTokens: string | null;
  outputTokens: string | null;
  cachedTokens: string | null;
  images: string | null;
  estimatedMicros: string | null;
}
export interface UsageReport {
  startUnixSeconds: number;
  endUnixSeconds: number;
  totals: {
    averageFirstEventMilliseconds?: number | null;
    p95FirstEventMilliseconds?: number | null;
    averageTotalMilliseconds?: number | null;
    admitted: number;
    recordedRejections: number;
    inFlight: number;
    unknown: number;
    usageUnknown?: number;
    unknownReasons?: Record<string, number>;
    complete: number;
    partial: number;
    unavailable: number;
    failed: number;
    cancelled: number;
    historicalWithoutTime: number;
    unresolvedExposureMicros: string;
    metrics: Metrics;
  };
  lifetimeGovernance: {
    keyID: string | null;
    inFlight: number;
    unknown: number;
    exposureMicros: string;
  };
  buckets: {
    atUnixSeconds: number;
    admitted: number;
    recordedRejections: number;
    unresolved: number;
  }[];
  rows: {
    kind: "admitted" | "rejected";
    id: string;
    atUnixSeconds: number;
    displayName?: string | null;
    principal?: string | null;
    firstEventMilliseconds?: number | null;
    totalMilliseconds?: number | null;
    keyID: string;
    model: string | null;
    mode: string;
    accountID: string | null;
    requestID: string | null;
    state: string | null;
    outcome: string | null;
    failure: string | null;
    completeness: string | null;
    metrics: Metrics;
  }[];
  nextCursor: string | null;
}
export interface UsageOptions {
  keys: string[];
  keyOptions?: {
    id: string;
    displayName?: string | null;
    principal: string | null;
  }[];
  models: string[];
  failures: string[];
}
const invalid = () => new ManagementError(0, "invalid_response");
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw invalid();
  return value as Record<string, unknown>;
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > maximum
  )
    throw invalid();
  return value;
}
function text(value: unknown, maximum = 256): string {
  if (
    typeof value !== "string" ||
    !value.length ||
    new TextEncoder().encode(value).length > maximum ||
    value.includes("\0")
  )
    throw invalid();
  return value;
}
function nullableText(value: unknown, maximum = 256): string | null {
  return value === null ? null : text(value, maximum);
}
function metric(value: unknown): string | null {
  if (value === null) return null;
  if (
    typeof value !== "string" ||
    !/^(0|[1-9][0-9]{0,18})$/.test(value) ||
    BigInt(value) > 9223372036854775807n
  )
    throw invalid();
  return value;
}
function requiredMetric(value: unknown): string {
  const result = metric(value);
  if (result === null) throw invalid();
  return result;
}
function metrics(raw: unknown): Metrics {
  const value = object(raw);
  return {
    imageInputTextTokens: metric(value.imageInputTextTokens ?? null),
    imageInputImageTokens: metric(value.imageInputImageTokens ?? null),
    imageInputTokens: metric(value.imageInputTokens ?? null),
    imageOutputTokens: metric(value.imageOutputTokens ?? null),
    inputTokens: metric(value.inputTokens),
    outputTokens: metric(value.outputTokens),
    cachedTokens: metric(value.cachedTokens),
    images: metric(value.images),
    estimatedMicros: metric(value.estimatedMicros),
  };
}
function oneOf(value: unknown, values: string[]): string {
  if (typeof value !== "string" || !values.includes(value)) throw invalid();
  return value;
}
function optionalEnum(value: unknown, values: string[]): string | null {
  return value === null ? null : oneOf(value, values);
}
export function parseUsage(raw: unknown): UsageReport {
  const value = object(raw),
    totals = object(value.totals),
    lifetime = object(value.lifetimeGovernance),
    policy = object(value.diagnosticsPolicy);
  const start = integer(value.startUnixSeconds, 1_000_000_000_000),
    end = integer(value.endUnixSeconds, 1_000_000_000_000);
  if (
    value.timezone !== "UTC" ||
    end <= start ||
    end - start > 31 * 86400 ||
    start % 3600 ||
    end % 3600 ||
    lifetime.scope !== "key_only_all_time" ||
    policy.days !== 30 ||
    policy.maximum !== 10000 ||
    policy.mayOmitUnderLoad !== true ||
    !Array.isArray(value.buckets) ||
    value.buckets.length !== (end - start) / 3600 ||
    !Array.isArray(value.rows) ||
    value.rows.length > 100
  )
    throw invalid();
  function latency(raw: unknown): number | null {
    if (raw == null) return null;
    if (
      typeof raw !== "number" ||
      !Number.isFinite(raw) ||
      raw < 0 ||
      raw > Number.MAX_SAFE_INTEGER
    )
      throw invalid();
    return raw;
  }
  const resultTotals = {
    averageFirstEventMilliseconds: latency(
      totals.averageFirstEventMilliseconds,
    ),
    p95FirstEventMilliseconds: latency(totals.p95FirstEventMilliseconds),
    averageTotalMilliseconds: latency(totals.averageTotalMilliseconds),
    admitted: integer(totals.admitted),
    recordedRejections: integer(totals.recordedRejections),
    inFlight: integer(totals.inFlight),
    unknown: integer(totals.unknown),
    usageUnknown: integer(totals.usageUnknown ?? totals.unknown),
    unknownReasons: Object.fromEntries(
      Object.entries(object(totals.unknownReasons ?? {})).map(
        ([reason, count]) => [text(reason, 64), integer(count)],
      ),
    ),
    complete: integer(totals.complete),
    partial: integer(totals.partial),
    unavailable: integer(totals.unavailable),
    failed: integer(totals.failed),
    cancelled: integer(totals.cancelled),
    historicalWithoutTime: integer(totals.historicalWithoutTime),
    unresolvedExposureMicros: requiredMetric(totals.unresolvedExposureMicros),
    metrics: metrics(totals.metrics),
  };
  if (
    (totals.usageUnknown !== undefined &&
      (resultTotals.usageUnknown > resultTotals.admitted ||
        Object.values(resultTotals.unknownReasons).reduce(
          (sum, count) => sum + count,
          0,
        ) !== resultTotals.usageUnknown)) ||
    resultTotals.complete + resultTotals.partial + resultTotals.unavailable !==
      resultTotals.admitted ||
    resultTotals.inFlight + resultTotals.unknown > resultTotals.admitted ||
    resultTotals.failed + resultTotals.cancelled > resultTotals.admitted
  )
    throw invalid();
  const buckets = value.buckets.map((raw, index) => {
    const item = object(raw);
    const at = integer(item.atUnixSeconds, 1_000_000_000_000);
    if (at !== start + index * 3600) throw invalid();
    return {
      atUnixSeconds: at,
      admitted: integer(item.admitted),
      recordedRejections: integer(item.recordedRejections),
      unresolved: integer(item.unresolved),
    };
  });
  if (
    buckets.reduce((sum, item) => sum + item.admitted, 0) !==
      resultTotals.admitted ||
    buckets.reduce((sum, item) => sum + item.recordedRejections, 0) !==
      resultTotals.recordedRejections ||
    buckets.reduce((sum, item) => sum + item.unresolved, 0) !==
      resultTotals.inFlight + resultTotals.unknown
  )
    throw invalid();
  const rows = value.rows.map((raw) => {
    const item = object(raw);
    const kind = oneOf(item.kind, ["admitted", "rejected"]) as
      "admitted" | "rejected";
    const at = integer(item.atUnixSeconds, 1_000_000_000_000);
    if (at < start || at >= end || (kind === "rejected" && item.state !== null))
      throw invalid();
    return {
      kind,
      id: text(item.id),
      atUnixSeconds: at,
      displayName: nullableText(item.displayName ?? null, 256),
      principal: nullableText(item.principal ?? null, 64),
      firstEventMilliseconds:
        item.firstEventMilliseconds == null
          ? null
          : integer(item.firstEventMilliseconds),
      totalMilliseconds:
        item.totalMilliseconds == null ? null : integer(item.totalMilliseconds),
      keyID: text(item.keyID),
      model: nullableText(item.model, 128),
      mode: oneOf(item.mode, ["generation", "warmup", "compact"]),
      accountID: nullableText(item.accountID),
      requestID: nullableText(item.requestID),
      state: optionalEnum(item.state, [
        "intent",
        "unknown",
        "settled",
        "closed_unknown",
      ]),
      outcome: optionalEnum(item.outcome, ["succeeded", "failed", "cancelled"]),
      failure: nullableText(item.failure, 64),
      completeness: optionalEnum(item.completeness, ["complete", "partial"]),
      metrics: metrics(item.metrics),
    };
  });
  const next = nullableText(value.nextCursor, 512);
  if (next && !/^[A-Za-z0-9_-]+$/.test(next)) throw invalid();
  return {
    startUnixSeconds: start,
    endUnixSeconds: end,
    totals: resultTotals,
    lifetimeGovernance: {
      keyID: nullableText(lifetime.keyID),
      inFlight: integer(lifetime.inFlight),
      unknown: integer(lifetime.unknown),
      exposureMicros: requiredMetric(lifetime.exposureMicros),
    },
    buckets,
    rows,
    nextCursor: next,
  };
}
export function defaults(): UsageFilters {
  return {
    start: new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10),
    end: new Date().toISOString().slice(0, 10),
    key: "",
    model: "",
    mode: "",
    failure: "",
    state: "",
    failedOnly: false,
  };
}
export function usageParameters(
  filters: UsageFilters,
  cursor: string | null = null,
): URLSearchParams {
  function day(value: string) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value))
      throw new ManagementError(400, "invalid_range");
    const epoch = Date.parse(value + "T00:00:00Z");
    if (
      !Number.isFinite(epoch) ||
      epoch < 0 ||
      new Date(epoch).toISOString().slice(0, 10) !== value
    )
      throw new ManagementError(400, "invalid_range");
    return epoch / 1000;
  }
  const currentHour = Math.floor(Date.now() / 3600000) * 3600;
  const start =
      filters.window?.start ??
      (filters.range === "24h" ? currentHour - 86400 : day(filters.start)),
    end =
      filters.window?.end ??
      (filters.range === "24h" ? currentHour : day(filters.end) + 86400);
  if (end <= start || end - start > 31 * 86400)
    throw new ManagementError(400, "invalid_range");
  const parameters = new URLSearchParams({
    start: String(start),
    end: String(end),
    limit: "50",
  });
  for (const name of ["key", "model", "mode", "failure", "state"] as const)
    if (filters[name].trim()) parameters.set(name, filters[name].trim());
  if (filters.failedOnly) parameters.set("failedOnly", "true");
  if (cursor) parameters.set("after", cursor);
  return parameters;
}
export async function fetchUsage(
  filters: UsageFilters,
  cursor: string | null,
  signal?: AbortSignal,
): Promise<UsageReport> {
  return parseUsage(
    await request("/api/usage?" + usageParameters(filters, cursor), { signal }),
  );
}
export async function fetchUsageOptions(
  signal?: AbortSignal,
): Promise<UsageOptions> {
  const value = object(await request("/api/usage/options", { signal }));
  function list(raw: unknown, maximum: number, length: number) {
    if (!Array.isArray(raw) || raw.length > maximum) throw invalid();
    const result = raw.map((item) => text(item, length));
    if (new Set(result).size !== result.length) throw invalid();
    return result;
  }
  return {
    keys: list(value.keys, 256, 256),
    keyOptions:
      value.keyOptions === undefined
        ? undefined
        : (() => {
            if (
              !Array.isArray(value.keyOptions) ||
              value.keyOptions.length > 256
            )
              throw invalid();
            return value.keyOptions.map((raw) => {
              const item = object(raw);
              return {
                id: text(item.id),
                displayName: nullableText(item.displayName ?? null, 256),
                principal: nullableText(item.principal, 64),
              };
            });
          })(),
    models: list(value.models, 48, 128),
    failures: list(value.failures, 32, 64),
  };
}

export interface KeyUsage {
  keyID: string;
  displayName?: string | null;
  principal: string | null;
  admitted: number;
  failed: number;
  pending: number;
  estimatedMicros: string | null;
  lastUsedAtUnixSeconds: number | null;
}
export async function fetchKeyUsage(signal?: AbortSignal): Promise<KeyUsage[]> {
  const value = object(await request("/api/usage/keys", { signal }));
  const start = integer(value.startUnixSeconds),
    end = integer(value.endUnixSeconds);
  if (
    value.timezone !== "UTC" ||
    start % 86400 ||
    end - start !== 86400 ||
    !Array.isArray(value.keys) ||
    value.keys.length > 256
  )
    throw invalid();
  return value.keys.map((raw) => {
    const item = object(raw);
    return {
      keyID: text(item.keyID),
      displayName: nullableText(item.displayName ?? null, 256),
      principal: nullableText(item.principal, 64),
      admitted: integer(item.admitted),
      failed: integer(item.failed),
      pending: integer(item.pending),
      estimatedMicros: metric(item.estimatedMicros),
      lastUsedAtUnixSeconds:
        item.lastUsedAtUnixSeconds === null
          ? null
          : integer(item.lastUsedAtUnixSeconds),
    };
  });
}
