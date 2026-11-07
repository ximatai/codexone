import { expect, it } from "vitest";
import { parseUsage } from "../usage/api";
import { reportFixture } from "../usage/usage.test-data";

it("keeps closed unknown state and reason counts separate from pending", () => {
  const raw = reportFixture();
  const report = parseUsage({
    ...raw,
    totals: {
      ...raw.totals,
      usageUnknown: 2,
      unknownReasons: { client_cancelled: 1, upstream_unavailable: 1 },
    },
    rows: raw.rows.map((row) => ({ ...row, state: "closed_unknown" })),
  });
  expect(report.totals.usageUnknown).toBe(2);
  expect(report.totals.unknownReasons?.client_cancelled).toBe(1);
  expect(report.rows[0].state).toBe("closed_unknown");
});
