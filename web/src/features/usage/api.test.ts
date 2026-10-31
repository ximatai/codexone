import { expect, it } from "vitest";
import { parseUsage, usageParameters } from "./api";
import { reportFixture } from "./usage.test-data";
it("keeps exact large integers and missing metrics, rejecting unsafe numeric transport and inconsistent buckets", () => {
  const fixture = reportFixture();
  expect(parseUsage(fixture).totals.metrics.inputTokens).toBe(
    "10000000000000001",
  );
  expect(
    parseUsage({
      ...fixture,
      totals: {
        ...fixture.totals,
        metrics: { ...fixture.totals.metrics, outputTokens: null },
      },
    }).totals.metrics.outputTokens,
  ).toBeNull();
  for (const value of [10000000000000000, "9223372036854775808", "-1", "01"])
    expect(() =>
      parseUsage({
        ...fixture,
        totals: {
          ...fixture.totals,
          metrics: { ...fixture.totals.metrics, inputTokens: value },
        },
      }),
    ).toThrow();
  expect(() => parseUsage({ ...fixture, buckets: [] })).toThrow();
  expect(() =>
    parseUsage({ ...fixture, totals: { ...fixture.totals, unknown: 3 } }),
  ).toThrow();
});
it("uses inclusive UTC days and strictly bounds the calendar range", () => {
  const filters = {
    start: "2026-10-01",
    end: "2026-10-31",
    key: "alpha",
    model: "synthetic-text",
    mode: "compact",
    failure: "deadline_exceeded",
    state: "unknown",
    failedOnly: true,
  };
  const params = usageParameters(filters, "cursor");
  expect(params.get("start")).toBe(
    String(Date.parse("2026-10-01T00:00:00Z") / 1000),
  );
  expect(params.get("end")).toBe(
    String(Date.parse("2026-11-01T00:00:00Z") / 1000),
  );
  expect(params.get("after")).toBe("cursor");
  expect(params.get("failedOnly")).toBe("true");
  for (const invalid of [
    { ...filters, start: "2026-02-30" },
    { ...filters, start: "2026-09-30" },
    { ...filters, start: "2026-11-01" },
  ])
    expect(() => usageParameters(invalid)).toThrow();
});

it("queries a rolling 24 completed UTC hours instead of the calendar day", () => {
  const parameters = usageParameters({
    start: "2026-10-01",
    end: "2026-10-31",
    key: "",
    model: "",
    mode: "",
    failure: "",
    state: "",
    failedOnly: false,
    range: "24h",
  });
  const end = Math.floor(Date.now() / 3600000) * 3600;
  expect(Number(parameters.get("end"))).toBe(end);
  expect(Number(parameters.get("start"))).toBe(end - 86400);
});

it("parses fractional filtered latency aggregates and rejects invalid values without treating missing evidence as zero", () => {
  const fixture = reportFixture();
  const totals = {
    ...fixture.totals,
    averageFirstEventMilliseconds: 12.5,
    p95FirstEventMilliseconds: 80,
    averageTotalMilliseconds: null,
  };
  expect(parseUsage({ ...fixture, totals }).totals).toMatchObject({
    averageFirstEventMilliseconds: 12.5,
    p95FirstEventMilliseconds: 80,
    averageTotalMilliseconds: null,
  });
  expect(parseUsage(fixture).totals.averageFirstEventMilliseconds).toBeNull();
  for (const value of [-1, Infinity, NaN, "20"]) {
    expect(() =>
      parseUsage({
        ...fixture,
        totals: { ...totals, averageFirstEventMilliseconds: value },
      }),
    ).toThrow();
  }
});
