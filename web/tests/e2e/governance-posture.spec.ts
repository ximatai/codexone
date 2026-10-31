import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";

test("explains closed unknown usage, reasons and detail retention on large and small screens", async ({
  page,
}) => {
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/session")
      return route.fulfill({
        json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      });
    if (url.pathname === "/api/usage/options")
      return route.fulfill({
        json: {
          keys: ["alpha"],
          models: ["synthetic-text"],
          failures: ["upstream_unavailable"],
        },
      });
    if (url.pathname === "/api/usage") {
      const report = reportFixture();
      return route.fulfill({
        json: {
          ...report,
          detailRetentionDays: 90,
          totals: {
            ...report.totals,
            usageUnknown: 1,
            unknownReasons: { upstream_unavailable: 1 },
          },
          rows: report.rows.map((row) => ({
            ...row,
            state: "closed_unknown",
            failure: "upstream_unavailable",
            completeness: null,
          })),
        },
      });
    }
    return route.fulfill({
      status: 404,
      json: { error: { code: "synthetic_not_found" } },
    });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/usage");
  await expect(
    page.getByRole("heading", { name: "用量与诊断", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("table").getByText("已关闭·用量未知", { exact: true }),
  ).toBeVisible();
  await page.getByText("更多统计与用量证据", { exact: true }).click();
  await expect(page.getByText("用量未知", { exact: true })).toBeVisible();
  await expect(page.getByText(/明细仅保留最近 90 天/)).toBeVisible();
  await mkdir("../artifacts/governance-posture", { recursive: true });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({
    path: "../artifacts/governance-posture/usage-1440.png",
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({
    path: "../artifacts/governance-posture/usage-390.png",
    fullPage: true,
  });
});
