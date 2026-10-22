import { expect, it } from "vitest";
import { parseUsage, usageParameters } from "./api";
import { reportFixture } from "./usage.test-data";
it("keeps exact large integers and missing metrics, rejecting unsafe numeric transport and inconsistent buckets", () => {
  const fixture = reportFixture();
  expect(parseUsage(fixture).totals.metrics.inputTokens).toBe("10000000000000001");
  expect(parseUsage({ ...fixture, totals: { ...fixture.totals, metrics: { ...fixture.totals.metrics, outputTokens: null } } }).totals.metrics.outputTokens).toBeNull();
  for (const value of [10000000000000000, "9223372036854775808", "-1", "01"]) expect(() => parseUsage({ ...fixture, totals: { ...fixture.totals, metrics: { ...fixture.totals.metrics, inputTokens: value } } })).toThrow();
  expect(() => parseUsage({ ...fixture, buckets: [] })).toThrow();
  expect(() => parseUsage({ ...fixture, totals: { ...fixture.totals, unknown: 3 } })).toThrow();
});
it("uses inclusive UTC days and strictly bounds the calendar range", () => {
  const filters = { start: "2026-10-01", end: "2026-10-31", key: "alpha", model: "synthetic-text", mode: "compact", failure: "deadline_exceeded", state: "unknown", failedOnly: true };
  const params = usageParameters(filters, "cursor");
  expect(params.get("start")).toBe(String(Date.parse("2026-10-01T00:00:00Z") / 1000));
  expect(params.get("end")).toBe(String(Date.parse("2026-11-01T00:00:00Z") / 1000));
  expect(params.get("after")).toBe("cursor"); expect(params.get("failedOnly")).toBe("true");
  for (const invalid of [{ ...filters, start: "2026-02-30" }, { ...filters, start: "2026-09-30" }, { ...filters, start: "2026-11-01" }]) expect(() => usageParameters(invalid)).toThrow();
});
