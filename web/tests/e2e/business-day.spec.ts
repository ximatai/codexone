import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { expectNoHorizontalOverflow } from "./layout";
import { mkdir } from "node:fs/promises";

for (const width of [1440, 390]) {
  test(`business-day dates use the server offset at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 950 });
    await page.clock.setFixedTime(new Date("2026-11-02T17:00:00Z"));
    await reviewFixture(page);
    const queries: URL[] = [];
    await page.route("**/api/usage/options", (route) =>
      route.fulfill({
        json: {
          timezone: "UTC+08:00",
          businessDay: { offsetMinutes: 480 },
          keys: [],
          models: ["synthetic-text"],
          failures: [],
        },
      }),
    );
    await page.route("**/api/usage?*", (route) => {
      const url = new URL(route.request().url());
      queries.push(url);
      const start = Number(url.searchParams.get("start"));
      const end = Number(url.searchParams.get("end"));
      const report = reportFixture();
      return route.fulfill({
        json: {
          ...report,
          timezone: "UTC+08:00",
          businessDay: { offsetMinutes: 480 },
          startUnixSeconds: start,
          endUnixSeconds: end,
          rows: [],
          buckets: Array.from({ length: (end - start) / 3600 }, (_, i) => ({
            atUnixSeconds: start + i * 3600,
            admitted: i === 0 ? report.totals.admitted : 0,
            recordedRejections: i === 0 ? report.totals.recordedRejections : 0,
            unresolved: i === 0 ? report.totals.unknown : 0,
          })),
          nextCursor: null,
        },
      });
    });
    await page.goto("/#/usage");
    await expect(page.getByText("请求明细", { exact: true })).toBeVisible();
    await expect.poll(() => queries.length).toBe(1);
    expect(queries[0].searchParams.get("end")).toBe(
      String(Date.parse("2026-11-03T16:00:00Z") / 1000),
    );
    await page.getByRole("button", { name: "自定义" }).click();
    await expect(
      page.getByRole("textbox", { name: "起始日（UTC+08:00）" }),
    ).toBeVisible();
    await expect(
      page.getByRole("textbox", { name: "结束日（UTC+08:00）" }),
    ).toHaveValue("2026-11-03");
    await expectNoHorizontalOverflow(page);
    await mkdir("../artifacts/business-day", { recursive: true });
    await page.screenshot({
      path: `../artifacts/business-day/usage-${width}.png`,
      fullPage: true,
    });
  });
}
