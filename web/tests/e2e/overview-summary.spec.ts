import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { expectNoHorizontalOverflow } from "./layout";
import { mkdir } from "node:fs/promises";

for (const width of [1920, 390]) {
  test(`active Key panel preserves observed cache, details and failure dates at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 1200 });
    await page.clock.install({ time: new Date("2026-11-03T02:00:00Z") });
    const state = await reviewFixture(page);
    state.accounts.splice(1);
    Object.assign(state.keys[0], {
      id: "high",
      principal: "legacy-p-synthetic",
      enabled: false,
    });
    state.alerts = 0;
    const start = Date.parse("2026-11-02T16:00:00Z") / 1000;
    const metadata = {
      timezone: "UTC+08:00",
      businessDay: { offsetMinutes: 480 },
    };
    const base = {
      enabled: true,
      admitted: 25,
      succeeded: 17,
      failed: 5,
      cancelled: 1,
      pending: 2,
      inFlight: 1,
      tokens: "10000000000000001",
      images: "3",
      tokenUsageIncomplete: true,
      inputTokens: "1000",
      cachedTokens: "250",
      cacheUsageIncomplete: true,
    };
    await page.route("**/api/usage/daily?*", (route) =>
      route.fulfill({
        json: {
          ...metadata,
          days: 7,
          buckets: Array.from({ length: 7 }, (_, i) => ({
            atUnixSeconds: start - (6 - i) * 86400,
            requests: 35,
            succeeded: 19,
            failed: 10,
            cancelled: 2,
            failures: { upstream_unavailable: 10 },
            metrics: {
              inputTokens: "2000",
              outputTokens: "300",
              cachedTokens: "250",
              images: null,
              estimatedMicros: "20",
            },
          })),
        },
      }),
    );
    let failKeys = false;
    await page.route("**/api/usage/keys*", (route) =>
      failKeys
        ? route.fulfill({
            status: 503,
            json: { error: { code: "synthetic_failure" } },
          })
        : route.fulfill({
            json: {
              ...metadata,
              startUnixSeconds: start,
              endUnixSeconds: start + 86400,
              keys: [
                {
                  ...base,
                  keyID: "high",
                  principal: "legacy-p-synthetic",
                  enabled: false,
                  lastUsedAtUnixSeconds: start + 2,
                },
                {
                  ...base,
                  keyID: "latest",
                  principal: "合成新设备",
                  displayName: "最近设备",
                  admitted: 10,
                  succeeded: 2,
                  failed: 5,
                  cachedTokens: "0",
                  lastUsedAtUnixSeconds: start + 3,
                },
                {
                  ...base,
                  keyID: "idle",
                  principal: "不应出现",
                  admitted: 0,
                  succeeded: 0,
                  failed: 0,
                  cancelled: 0,
                  inFlight: 0,
                },
              ],
            },
          }),
    );
    await page.route("**/api/usage/options", (route) =>
      route.fulfill({
        json: {
          ...metadata,
          keys: ["high"],
          models: ["synthetic-text"],
          failures: [],
        },
      }),
    );
    const queries: URL[] = [];
    await page.route("**/api/usage?*", (route) => {
      const url = new URL(route.request().url());
      queries.push(url);
      const report = reportFixture();
      return route.fulfill({
        json: {
          ...report,
          ...metadata,
          startUnixSeconds: start,
          endUnixSeconds: start + 86400,
          totals: {
            ...report.totals,
            admitted: 5,
            failed: 5,
            cancelled: 0,
            inFlight: 0,
            unknown: 0,
            complete: 5,
            partial: 0,
            unavailable: 0,
            recordedRejections: 0,
          },
          buckets: Array.from({ length: 24 }, (_, i) => ({
            atUnixSeconds: start + i * 3600,
            admitted: i === 0 ? 5 : 0,
            recordedRejections: 0,
            unresolved: 0,
          })),
          rows: [],
          nextCursor: null,
        },
      });
    });
    await page.goto("/");
    const panel = page.getByRole("region", { name: "今日 Key 请求汇总" });
    await expect(
      panel.getByRole("link", { name: "未命名 Key", exact: true }),
    ).toBeVisible();
    await expect(panel.getByText("不应出现", { exact: true })).toHaveCount(0);
    await expect(panel.getByText("全部", { exact: true })).toHaveCount(0);
    await expect(panel.getByText("已停用", { exact: true })).toBeVisible();
    await expect(panel.getByText("失败偏高", { exact: true })).toHaveCount(0);
    await expect(
      panel.getByTitle(/部分请求/).filter({ hasText: /^25%$/ }),
    ).toBeVisible();
    await expect(panel.getByText("0%", { exact: true })).toBeVisible();
    await expect(panel.getByLabel("取消 1", { exact: true })).toHaveCount(2);
    await expect(panel.getByLabel("结果未明 1", { exact: true })).toHaveCount(
      2,
    );
    const first = panel.locator("tbody tr").first();
    await expect(first).toContainText("最近设备");
    const name = panel.getByRole("link", { name: "未命名 Key", exact: true });
    await name.focus();
    await name.press("Enter");
    const detail = page.getByRole("dialog", { name: "密钥详情" });
    await expect(detail).toContainText("legacy-p-synthetic");
    await expect(
      detail.getByRole("button", { name: "保存修改" }),
    ).toBeVisible();
    await detail.getByRole("button", { name: "关闭", exact: true }).click();
    await expect(detail).toBeHidden();
    await page.goBack();
    if (width > 750) {
      await expect(
        panel.getByRole("columnheader", { name: "生图张数" }),
      ).toBeVisible();
    }
    await expect(
      panel
        .getByRole("row")
        .filter({ hasText: "未命名 Key" })
        .getByTitle("3", { exact: true }),
    ).toHaveText("3");
    await expectNoHorizontalOverflow(page);
    await mkdir("../artifacts/business-day", { recursive: true });
    await page.screenshot({
      path: `../artifacts/business-day/panel-${width}.png`,
      fullPage: true,
    });
    failKeys = true;
    await page.clock.runFor(15000);
    await expect(panel.getByText(/更新失败 · 上次更新/)).toBeVisible();
    await page.clock.setFixedTime(new Date("2026-11-04T02:00:00Z"));
    await panel.getByRole("link", { name: /^未命名 Key 失败率 / }).click();
    await expect(page.getByText("请求明细", { exact: true })).toBeVisible();
    await expect(page.getByLabel("当前结果筛选")).toContainText(
      "请求结果：失败",
    );
    expect(queries[0].searchParams.get("start")).toBe(String(start));
    expect(queries[0].searchParams.get("end")).toBe(String(start + 86400));
    expect(queries[0].searchParams.get("outcome")).toBe("failed");
    expect(page.url()).toContain("start=2026-11-03");
    expect(page.url()).toContain("end=2026-11-03");
    await expectNoHorizontalOverflow(page);
  });
}

test("overview empty active list has no range toggle", async ({ page }) => {
  const state = await reviewFixture(page);
  state.empty = true;
  await page.goto("/");
  const panel = page.getByRole("region", { name: "今日 Key 请求汇总" });
  await expect(panel.getByText("暂无活跃 Key", { exact: true })).toBeVisible();
  await expect(
    panel.getByRole("textbox", { name: "Key 展示范围" }),
  ).toHaveCount(0);
  await expect(panel.getByText("全部", { exact: true })).toHaveCount(0);
});
