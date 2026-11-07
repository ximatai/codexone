import { act, renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { tokenTotal, type DailyBucket } from "./round2-api";
import { useOverviewRefresh } from "./useOverviewRefresh";
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
it("converts token data without counting cache twice or filling missing evidence", () => {
  const bucket = {
    metrics: { inputTokens: "100", cachedTokens: "80", outputTokens: "20" },
  } as DailyBucket;
  expect(tokenTotal(bucket)).toBe(120);
  expect(
    tokenTotal({
      metrics: { inputTokens: "100", outputTokens: null },
    } as DailyBucket),
  ).toBeNull();
  expect(
    tokenTotal({
      metrics: { inputTokens: null, outputTokens: null },
    } as DailyBucket),
  ).toBeNull();
});
it("pauses polling while hidden and resumes when visible", () => {
  vi.useFakeTimers();
  const hidden = vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  const { result, unmount } = renderHook(() => useOverviewRefresh());
  expect(result.current.interval).toBe(15000);
  act(() => {
    hidden.mockReturnValue(true);
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(result.current.interval).toBe(false);
  act(() => {
    hidden.mockReturnValue(false);
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(result.current.interval).toBe(15000);
  unmount();
});
it("rejects malformed daily counts and preserves missing evidence", async () => {
  const { fetchDaily } = await import("./round2-api");
  const bucket = {
    atUnixSeconds: 0,
    requests: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    failures: {},
    metrics: {
      inputTokens: null,
      outputTokens: null,
      cachedTokens: null,
      images: null,
      estimatedMicros: null,
    },
  };
  const reply = { timezone: "UTC", days: 1, buckets: [bucket] };
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({ ok: true, json: async () => reply }),
  );
  expect(
    (await fetchDaily(new AbortController().signal)).buckets[0].metrics
      .estimatedMicros,
  ).toBeNull();
  bucket.requests = -1;
  await expect(fetchDaily(new AbortController().signal)).rejects.toThrow();
});
it("accepts omitted optional live observation fields", async () => {
  const { fetchInFlight } = await import("./round2-api");
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        rows: [
          {
            id: "synthetic",
            keyID: "alpha",
            accountID: "synthetic-account",
            mode: "generation",
          },
        ],
      }),
    }),
  );
  const rows = await fetchInFlight(new AbortController().signal);
  expect(rows[0].hasFirstEvent).toBeUndefined();
  expect(rows[0].principal).toBeUndefined();
});
it("validates cache numerators and server window metadata", async () => {
  const { fetchKeySummary } = await import("./round2-api");
  const key = {
    keyID: "synthetic",
    principal: "p",
    admitted: 2,
    succeeded: 1,
    failed: 1,
    cancelled: 0,
    inFlight: 0,
    pending: 1,
    tokens: "10",
    inputTokens: "10",
    cachedTokens: "0",
    cacheUsageIncomplete: true,
  };
  const reply = {
    timezone: "UTC+08:00",
    businessDay: { offsetMinutes: 480 },
    startUnixSeconds: 1793635200,
    endUnixSeconds: 1793721600,
    keys: [key],
  };
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({ ok: true, json: async () => reply }),
  );
  expect(
    (await fetchKeySummary(new AbortController().signal)).keys[0].cachedTokens,
  ).toBe("0");
  key.cachedTokens = "11";
  await expect(fetchKeySummary(new AbortController().signal)).rejects.toThrow();
  key.cachedTokens = "0";
  reply.timezone = "UTC";
  await expect(fetchKeySummary(new AbortController().signal)).rejects.toThrow();
});
