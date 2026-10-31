import { act, renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import {
  change,
  pointChange,
  tokenTotal,
  type DailyBucket,
} from "./round2-api";
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
  expect(change(2, 0)).toBe("较昨日新增");
  expect(change(null, 2)).toBe("较昨日不可用");
  expect(change(3, 2)).toBe("较昨日 +50.0%");
  expect(pointChange(2, 1)).toBe("较昨日 +1.0 个百分点");
  expect(pointChange(1, 1.01)).toBe("较昨日持平");
  expect(pointChange(null, 1)).toBe("较昨日不可用");
});
it("pauses auto refresh while hidden, resumes when visible, and honors switch", () => {
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
  act(() => result.current.setAutomatic(false));
  expect(result.current.interval).toBe(false);
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
  const reply = { timezone: "UTC", days: 7, buckets: [bucket] };
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({ ok: true, json: async () => reply }),
  );
  expect(
    (await fetchDaily(new AbortController().signal))[0].metrics.estimatedMicros,
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
