import { screen, within } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { KeyResults, cacheRate, failureLink, highFailure } from "./KeyResults";
import type { KeySummary, KeySummaryReport } from "./round2-api";
import type { UseQueryResult } from "@tanstack/react-query";
const row: KeySummary = {
  keyID: "synthetic-key",
  principal: "legacy-p-synthetic",
  admitted: 20,
  failed: 5,
  succeeded: 10,
  cancelled: 1,
  inFlight: 1,
  pending: 0,
  tokens: "10000000000000001",
  images: "3",
  tokenUsageIncomplete: true,
  inputTokens: "1000",
  cachedTokens: "250",
  cacheUsageIncomplete: true,
  lastUsedAtUnixSeconds: 1793635200,
};
const report: KeySummaryReport = {
  timezone: "UTC+08:00",
  businessDay: { offsetMinutes: 480 },
  startUnixSeconds: 1793635200,
  endUnixSeconds: 1793721600,
  keys: [row],
};
function query(data = report) {
  return {
    data,
    isPending: false,
    isError: false,
    dataUpdatedAt: 1793640000000,
    refetch: vi.fn(),
  } as unknown as UseQueryResult<KeySummaryReport, Error>;
}
it("uses weighted observed cache even with missing requests, exact large integers and real zero", () => {
  expect(cacheRate(row)).toBe("25%");
  expect(cacheRate({ ...row, cachedTokens: "0" })).toBe("0%");
  expect(cacheRate({ ...row, inputTokens: "0", cachedTokens: "0" })).toBe("—");
  expect(cacheRate({ ...row, inputTokens: null, cachedTokens: null })).toBe(
    "—",
  );
  expect(
    cacheRate({
      ...row,
      inputTokens: "1000000000000000000",
      cachedTokens: "500000000000000000",
    }),
  ).toBe("50%");
});
it("highlights only the 20/5/20 percent rule including equality", () => {
  for (const [admitted, failed, high] of [
    [19, 5, false],
    [20, 4, false],
    [25, 5, true],
    [26, 5, false],
    [20, 5, true],
  ] as const)
    expect(highFailure({ admitted, failed, cancelled: 0 })).toBe(high);
  expect(highFailure({ admitted: 30, failed: 5, cancelled: 5 })).toBe(true);
});
it("uses summary dates for failure links even after midnight", () => {
  const url = new URL(failureLink(row, report), "https://synthetic.invalid");
  expect(Object.fromEntries(url.searchParams)).toEqual({
    key: row.keyID,
    start: "2026-11-03",
    end: "2026-11-03",
    outcome: "failed",
  });
});
it("shows image counts and links each active Key to its management drawer", () => {
  const other = {
    ...row,
    keyID: "a",
    displayName: "较新 Key",
    tokens: "10000000000000000",
    images: "0",
    lastUsedAtUnixSeconds: row.lastUsedAtUnixSeconds! + 1,
  };
  const result = render(
    <KeyResults
      query={query({
        ...report,
        keys: [
          other,
          {
            ...row,
            admitted: 0,
            failed: 0,
            succeeded: 0,
            cancelled: 0,
            inFlight: 0,
            keyID: "idle",
            displayName: "闲置 Key",
          },
          row,
        ],
      })}
    />,
  );
  expect(
    screen.getAllByRole("columnheader").map((cell) => cell.textContent),
  ).toEqual([
    "Key",
    "最近活动",
    "请求",
    "失败率",
    "Token",
    "生图张数",
    "缓存命中率",
  ]);
  expect(screen.queryByText("闲置 Key")).toBeNull();
  const rows = screen.getAllByRole("row").slice(1);
  expect(
    within(rows[0]).getByRole("link", { name: "未命名 Key" }),
  ).toBeVisible();
  expect(screen.queryByText(row.principal!)).toBeNull();
  expect(
    within(rows[0]).getByTitle(/部分请求没有完整宿主用量/),
  ).toHaveTextContent("25%");
  expect(screen.getAllByLabelText("取消 1")[0]).toBeVisible();
  expect(screen.getAllByLabelText("结果未明 3")[0]).toBeVisible();
  expect(within(rows[0]).getByTitle("3")).toHaveTextContent("3");
  expect(within(rows[1]).getByTitle("0")).toHaveTextContent("0");
  const href = within(rows[0])
    .getByRole("link", { name: "未命名 Key" })
    .getAttribute("href")!;
  expect(
    new URL(href, "https://synthetic.invalid").searchParams.get("detail"),
  ).toBe(row.keyID);
  result.rerender(
    <KeyResults
      query={query({
        ...report,
        keys: [{ ...other, tokens: row.tokens }, row],
      })}
    />,
  );
  expect(
    within(screen.getAllByRole("row")[1]).getByRole("link", {
      name: "较新 Key",
    }),
  ).toBeVisible();
  result.rerender(
    <KeyResults
      query={query({
        ...report,
        keys: [
          row,
          {
            ...other,
            tokens: row.tokens,
            lastUsedAtUnixSeconds: row.lastUsedAtUnixSeconds,
          },
        ],
      })}
    />,
  );
  expect(
    within(screen.getAllByRole("row")[1]).getByRole("link", {
      name: "较新 Key",
    }),
  ).toBeVisible();
});

it("shows all active Keys and leaves missing image counts unavailable", () => {
  const keys = Array.from({ length: 40 }, (_, index) => ({
    ...row,
    images: undefined,
    keyID: `synthetic-bounded-${index}`,
    displayName: `合成 Key ${index}`,
  }));
  render(<KeyResults query={query({ ...report, keys })} />);
  const panel = screen.getByRole("region", { name: "今日 Key 请求汇总" });
  expect(within(panel).getAllByRole("row")).toHaveLength(41);
  expect(within(panel).getAllByTitle("无图片产出观测")).toHaveLength(40);
  expect(
    within(panel).getByRole("link", { name: "合成 Key 39" }),
  ).toBeVisible();
});
