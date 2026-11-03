import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { expectNoHorizontalOverflow } from "./layout";
test("overview filters active and all unarchived Keys with compact exact metrics", async ({
  page,
}, info) => {
  const state = await reviewFixture(page);
  state.accounts.splice(1);
  state.alerts = 0;
  const now = Math.floor(Date.now() / 1000);
  await page.route("**/api/usage/keys*", (route) =>
    route.fulfill({
      json: {
        timezone: "UTC",
        startUnixSeconds: Math.floor(now / 86400) * 86400,
        endUnixSeconds: (Math.floor(now / 86400) + 1) * 86400,
        keys: [
          {
            keyID: "synthetic-active",
            enabled: false,
            displayName: "工作站",
            principal: "synthetic-active",
            admitted: 10,
            succeeded: 4,
            failed: 2,
            cancelled: 1,
            pending: 4,
            inFlight: 1,
          },
          {
            keyID: "synthetic-idle",
            displayName: "备用设备",
            principal: "synthetic-idle",
            admitted: 0,
            succeeded: 0,
            failed: 0,
            cancelled: 0,
            pending: 0,
            inFlight: 0,
          },
        ],
      },
    }),
  );
  await page.route("**/api/usage/daily?*", (route) =>
    route.fulfill({
      json: {
        timezone: "UTC",
        days: 7,
        buckets: [
          {
            atUnixSeconds: Math.floor(now / 86400) * 86400,
            requests: 10,
            succeeded: 4,
            failed: 2,
            cancelled: 1,
            failures: { upstream_rejected: 2 },
            metrics: {
              inputTokens: "2000000000000",
              outputTokens: "234",
              cachedTokens: "0",
              images: null,
              estimatedMicros: "20",
            },
          },
        ],
      },
    }),
  );
  await page.route("**/api/usage/headroom", (route) =>
    route.fulfill({
      json: {
        capacities: [
          {
            name: "daily_requests",
            current: "90",
            limit: "100",
            blocking: false,
          },
          {
            name: "daily_estimated_micros",
            current: "20",
            limit: "100",
            blocking: false,
          },
        ],
        accounts: [
          {
            id: "synthetic-account-0",
            current: 4,
            peak24Hours: 12,
            limit: 16,
            blocking: true,
          },
        ],
        unknownReconciliation: {
          count: 3,
          beforeUnixSeconds: now - 86400,
          periodSeconds: 86400,
        },
      },
    }),
  );
  await page.setViewportSize({ width: 1920, height: 1680 });
  await page.goto("/");
  await expect(page.getByText("2 万亿", { exact: true })).toHaveAttribute(
    "title",
    "2,000,000,000,234",
  );
  const summary = page.getByRole("region", { name: "今日 Key 请求汇总" });
  await expect(summary.getByText("工作站", { exact: true })).toBeVisible();
  await expect(summary.getByText("备用设备", { exact: true })).toHaveCount(0);
  await expect(summary.getByText("已停用", { exact: true })).toBeVisible();
  await summary.getByText("全部", { exact: true }).click();
  await expect(summary.getByText("备用设备", { exact: true })).toBeVisible();
  await expect(summary.getByLabel("结果未明 2", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "最近请求", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByText("参考阈值 $0.0001 · 已用 20.0%", { exact: true }),
  ).toBeVisible();
  expect(state.reads.some((row) => row.path === "/api/usage")).toBe(false);
  await expect(summary.getByLabel("执行中 1", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "运行状态", exact: true }),
  ).toBeInViewport();
  expect(
    await page
      .getByRole("heading", { name: "进行中请求", exact: true })
      .locator("..")
      .locator("..")
      .evaluate((node) => node.getBoundingClientRect().height),
  ).toBeLessThan(140);
  await expectNoHorizontalOverflow(page);
  await page.screenshot({
    path: info.outputPath("overview-wide.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expectNoHorizontalOverflow(page);
  await expect(summary.getByText("备用设备", { exact: true })).toBeVisible();
  await summary.getByText("今日活跃", { exact: true }).click();
  await expect(summary.getByText("备用设备", { exact: true })).toHaveCount(0);
  await page.screenshot({
    path: info.outputPath("overview-narrow.png"),
    fullPage: true,
  });
});

test("overview empty active list keeps the all filter available", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.empty = true;
  await page.goto("/");
  const summary = page.getByRole("region", { name: "今日 Key 请求汇总" });
  await expect(
    summary.getByText("今日暂无活跃 Key。", { exact: true }),
  ).toBeVisible();
  await summary.getByText("全部", { exact: true }).click();
  await expect(
    summary.getByText("暂无未归档 Key。", { exact: true }),
  ).toBeVisible();
  await summary.getByText("今日活跃", { exact: true }).click();
  await expect(
    summary.getByText("今日暂无活跃 Key。", { exact: true }),
  ).toBeVisible();
});
