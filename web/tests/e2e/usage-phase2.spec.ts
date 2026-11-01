import { expectNoHorizontalOverflow } from "./layout";
import { expect, test, gotoUsage } from "./fixtures";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";

test("usage filters, cursor pages and request drawer stay usable on desktop and mobile", async ({
  page,
}) => {
  const now = new Date("2026-10-31T23:41:00Z");
  const presetEnd = Date.parse("2026-10-31T23:00:00Z") / 1000;
  const isPresetQuery = (url: URL) =>
    url.pathname === "/api/usage" &&
    url.searchParams.get("start") === String(presetEnd - 86400) &&
    url.searchParams.get("end") === String(presetEnd);
  let releasePresetRead!: () => void;
  const presetRead = new Promise<void>((resolve) => {
    releasePresetRead = resolve;
  });
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
      if (isPresetQuery(url)) await presetRead;
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
  await gotoUsage(page, now);
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-admin-only");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(
    page.getByRole("heading", { name: "用量与诊断", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("第 1 页", { exact: true })).toBeVisible();
  await expect(page).toHaveURL(/page=1/);
  const presetButton = page.getByRole("button", { name: "最近 24 小时" });
  const presetResponse = page.waitForResponse((response) =>
    isPresetQuery(new URL(response.url())),
  );
  await presetButton.click();
  await expect.poll(() => queries.some(isPresetQuery)).toBe(true);
  // Dispatch is not completion: the applied preset must wait for the response.
  await expect(presetButton).toBeDisabled();
  await expect(presetButton).toHaveAttribute("aria-pressed", "false");
  releasePresetRead();
  const response = await presetResponse;
  await expect(presetButton).toBeEnabled();
  await expect(presetButton).toHaveAttribute("aria-pressed", "true");
  await expect(
    page.getByRole("button", { name: "自定义", exact: true }),
  ).toHaveAttribute("aria-pressed", "false");
  const firstStart = new URL(response.url()).searchParams.get("start");
  const nextPageResponse = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return isPresetQuery(url) && url.searchParams.has("after");
  });
  await page.getByRole("button", { name: "下一页" }).click();
  await expect(page.getByText("第 2 页", { exact: true })).toBeVisible();
  const nextPage = new URL((await nextPageResponse).url());
  expect(nextPage.searchParams.get("after")).toBe("synthetic_cursor");
  expect(nextPage.searchParams.get("start")).toBe(firstStart);
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
  await expect(drawer).toContainText("首事件耗时");
  await expect(drawer).toContainText("总耗时");
  await page.waitForTimeout(300);
  await page.screenshot({
    path: "../artifacts/ui-phase2/usage-detail-1440.png",
  });
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(drawer).toBeHidden();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await expectNoHorizontalOverflow(page);
  await page.screenshot({
    path: "../artifacts/ui-phase2/usage-390.png",
  });
});
