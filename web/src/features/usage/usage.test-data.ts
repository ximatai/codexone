export function reportFixture() {
  const start = Date.parse("2026-10-22T00:00:00Z") / 1000;
  const metrics = {
    inputTokens: "10000000000000001",
    outputTokens: "0",
    cachedTokens: "0",
    images: "0",
    estimatedMicros: "10",
  };
  return {
    timezone: "UTC",
    startUnixSeconds: start,
    endUnixSeconds: start + 86400,
    totals: {
      admitted: 2,
      recordedRejections: 1,
      inFlight: 0,
      unknown: 1,
      complete: 1,
      partial: 0,
      unavailable: 1,
      failed: 0,
      cancelled: 1,
      historicalWithoutTime: 1,
      unresolvedExposureMicros: "10",
      metrics,
    },
    lifetimeGovernance: {
      scope: "key_only_all_time",
      keyID: "alpha",
      inFlight: 0,
      unknown: 3,
      exposureMicros: "30",
    },
    diagnosticsPolicy: { days: 30, maximum: 10000, mayOmitUnderLoad: true },
    buckets: Array.from({ length: 24 }, (_, i) => ({
      atUnixSeconds: start + i * 3600,
      admitted: i === 0 ? 2 : 0,
      recordedRejections: i === 0 ? 1 : 0,
      unresolved: i === 0 ? 1 : 0,
    })),
    rows: [
      {
        kind: "admitted",
        id: "first",
        atUnixSeconds: start,
        keyID: "alpha",
        model: "synthetic-text",
        mode: "generation",
        accountID: null,
        requestID: "request-first",
        state: "settled",
        outcome: "succeeded",
        failure: null,
        completeness: "complete",
        metrics,
      },
    ],
    nextCursor: "synthetic_cursor",
  };
}
