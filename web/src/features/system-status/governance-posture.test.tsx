import { expect, it } from "vitest";
import { attentionMessage } from "./attention-api";
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
it("labels exceeded references as warnings and explains high quota rankings", () => {
  const base = {
    severity: "warning" as const,
    subjectType: "system" as const,
    subjectID: null,
    subjectName: null,
    sinceUnixSeconds: null,
  };
  expect(
    attentionMessage({
      ...base,
      kind: "capacity_reference",
      detail: {
        metric: "daily_requests",
        current: "101",
        limit: "100",
        exceeded: true,
      },
    }),
  ).toContain("已超过参考上限");
  expect(
    attentionMessage({
      ...base,
      kind: "quota_high",
      detail: { keyRanking: "synthetic-key: unknown" },
    }),
  ).toContain("已观测下界");
});
