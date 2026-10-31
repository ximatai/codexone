import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";

test("usage filters, cursor pages and request drawer stay usable on desktop and mobile", async ({
  page,
}) => {
  let authenticated = false;
  const queries: URL[] = [];
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/session") {
      if (route.request().method() === "POST") authenticated = true;
      return route.fulfill({
        status: authenticated ? 200 : 401,
        json: authenticated
          ? { authenticated: true, csrf: "ac1_" + "a".repeat(43) }
          : { error: { code: "unauthorized" } },
      });
    }
    if (url.pathname === "/api/usage/options")
      return route.fulfill({
        json: {
          keys: ["alpha"],
          keyOptions: [{ id: "alpha", principal: "合成团队" }],
          models: ["synthetic-text"],
          failures: ["rate_limited"],
        },
      });
    if (url.pathname === "/api/usage") {
      queries.push(url);
      const report = reportFixture();
      return route.fulfill({
        json: {
          ...report,
          totals: {
            ...report.totals,
            averageFirstEventMilliseconds: 12,
            p95FirstEventMilliseconds: 20,
            averageTotalMilliseconds: 34,
            metrics: {
              ...report.totals.metrics,
              inputTokens: "12000",
              outputTokens: "2000",
              estimatedMicros: "250000",
            },
          },
          rows: report.rows.map((row) => ({
            ...row,
            principal: "合成团队",
            firstEventMilliseconds: 12,
            totalMilliseconds: 34,
          })),
        },
      });
    }
    return route.fulfill({
      status: 404,
      json: { error: { code: "synthetic_not_found" } },
    });
  });
  await mkdir("../artifacts/ui-phase2", { recursive: true });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/usage");
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-admin-only");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(
    page.getByRole("heading", { name: "用量与诊断", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("第 1 页", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "最近 24 小时" }).click();
  await expect.poll(() => queries.length).toBe(2);
  const firstStart = queries[1].searchParams.get("start");
  await page.getByRole("button", { name: "下一页" }).click();
  await expect(page.getByText("第 2 页", { exact: true })).toBeVisible();
  expect(queries[2].searchParams.get("after")).toBe("synthetic_cursor");
  expect(queries[2].searchParams.get("start")).toBe(firstStart);
  await page.getByText("更多筛选", { exact: true }).click();
  await page.getByLabel("执行模式").selectOption("compact");
  await page.getByRole("button", { name: "查询用量", exact: true }).click();
  await expect
    .poll(() => queries.at(-1)?.searchParams.get("mode"))
    .toBe("compact");
  await expect(page.getByText("第 1 页", { exact: true })).toBeVisible();
  await page.getByText("更多筛选", { exact: true }).click();
  await page.getByRole("button", { name: "自定义", exact: true }).click();
  await expect(page.getByLabel("起始日（UTC）")).toBeVisible();
  await page.getByRole("button", { name: "自定义", exact: true }).click();
  await page.screenshot({
    path: "../artifacts/ui-phase2/usage-1440.png",
  });
  await page.locator(".usage-table tbody tr").first().click();
  const drawer = page.getByRole("dialog", { name: "请求详情" });
  await expect(page.locator("body")).toHaveCSS("overflow", "hidden");
  await expect(drawer).toContainText("request-first");
  await expect(drawer).toContainText("合成团队");
  await expect(drawer).toContainText("首事件耗时：12 ms");
  await expect(drawer).toContainText("总耗时：34 ms");
  await page.waitForTimeout(300);
  await page.screenshot({
    path: "../artifacts/ui-phase2/usage-detail-1440.png",
  });
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(drawer).toBeHidden();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({
    path: "../artifacts/ui-phase2/usage-390.png",
  });
});
