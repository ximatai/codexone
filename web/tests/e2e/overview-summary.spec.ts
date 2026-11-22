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
      tokens: "1500000",
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
                  tokenBreakdown: { input: "1200000", output: "300000" },
                  enabled: false,
                  estimatedMicros: "0",
                  priceUsageIncomplete: false,
                  firstUsedTodayAtUnixSeconds: start + 60,
                  lastUsedTodayAtUnixSeconds: start + 120,
                  lastUsedAtUnixSeconds: start + 86400,
                },
                {
                  ...base,
                  keyID: "latest",
                  principal: "合成新设备",
                  displayName: "最近设备",
                  estimatedMicros: "1250000",
                  priceUsageIncomplete: true,
                  tokenBreakdown: { input: "1250000", output: "250000" },
                  admitted: 10,
                  succeeded: 2,
                  failed: 5,
                  cachedTokens: "0",
                  firstUsedTodayAtUnixSeconds: start + 180,
                  lastUsedTodayAtUnixSeconds: start + 180,
                  lastUsedAtUnixSeconds: start + 180,
                },
                {
                  ...base,
                  keyID: "unrecorded",
                  displayName: "未记录设备",
                  admitted: 1,
                  succeeded: 1,
                  failed: 0,
                  cancelled: 0,
                  inFlight: 0,
                  pending: 0,
                  inputTokens: null,
                  cachedTokens: null,
                  tokens: null,
                  tokenBreakdown: { input: null, output: null },
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
    const share = page.getByRole("region", { name: "今日 Key 用量占比" });
    const rate = page.getByRole("heading", { name: "Token 输出速率" });
    const metrics = page.getByLabel("关键指标", { exact: true });
    const requests = page.getByRole("heading", { name: "进行中请求" });
    await expect(
      share.getByText("输入 + 输出 Token · 2026-11-03"),
    ).toBeVisible();
    await expect(share.getByRole("listitem")).toHaveCount(3);
    await expect(
      share.getByRole("listitem").filter({ hasText: "最近设备" }),
    ).toContainText("50%");
    await expect(share.getByTitle("≥ 1,500,000 Token")).toHaveCount(2);
    await expect(
      share.getByRole("listitem").filter({ hasText: "未记录设备" }),
    ).toHaveText("未记录设备未记录—");
    const [metricsBox, shareBox, rateBox, requestsBox] = await Promise.all(
      [metrics, share, rate, requests].map((item) => item.boundingBox()),
    );
    expect(shareBox!.y).toBeGreaterThan(metricsBox!.y + metricsBox!.height);
    expect(requestsBox!.y).toBeGreaterThan(
      Math.max(rateBox!.y, shareBox!.y + shareBox!.height),
    );
    if (width > 750) {
      expect(rateBox!.x).toBeGreaterThan(shareBox!.x + shareBox!.width);
      expect(rateBox!.y).toBeLessThan(shareBox!.y + shareBox!.height);
    } else {
      expect(rateBox!.y).toBeGreaterThan(shareBox!.y + shareBox!.height);
    }
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
    const first = panel.locator("tbody tr").first();
    await expect(first.getByText("0%", { exact: true })).toBeVisible();
    await expect(panel.getByLabel("取消 1", { exact: true })).toHaveCount(2);
    await expect(panel.getByLabel("结果未明 1", { exact: true })).toHaveCount(
      2,
    );
    await expect(first).toContainText("最近设备");
    await expect(first).toContainText("最早 00:03");
    await expect(first).toContainText("最近 00:03");
    await expect(
      first.getByTitle("输入 Token 已观测下界 1,250,000"),
    ).toHaveText("输入 ≥ 125 万");
    await expect(first.getByTitle("输出 Token 已观测下界 250,000")).toHaveText(
      "输出 ≥ 25 万",
    );
    const second = panel.getByRole("row").filter({ hasText: "未命名 Key" });
    await expect(second).toContainText("输入 ≥ 120 万");
    await expect(second).toContainText("输出 ≥ 30 万");
    await expect(first.getByTitle(/已观测费用下界/)).toHaveText("≥ $1.25");
    await expect(second.getByTitle(/按配置费率估算/)).toHaveText("$0.00");
    await expect(panel.getByTitle("估算费用未记录")).toHaveText("—");
    if (width <= 750) {
      await expect(first.getByText("估算费用", { exact: true })).toBeVisible();
    }
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
        panel.getByRole("columnheader", { name: "生图", exact: true }),
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
    await panel.screenshot({
      path: `../artifacts/business-day/key-token-breakdown-${width}.png`,
    });
    const donutTop = async (card: typeof share) =>
      (await card.locator("svg").first().boundingBox())!.y -
      (await card.boundingBox())!.y;
    const previousDonutTop = await donutTop(share);
    failKeys = true;
    await page.clock.setFixedTime(new Date("2026-11-04T02:00:00Z"));
    await page.clock.runFor(15000);
    await expect(panel.getByText(/更新失败 · 上次更新/)).toBeVisible();
    await expect(share).toHaveCount(0);
    const previousShare = page.getByRole("region", {
      name: "Key 用量占比",
      exact: true,
    });
    await expect(previousShare).toContainText("旧业务日快照 · 2026-11-03");
    await expect(previousShare.getByRole("listitem")).toHaveCount(3);
    expect(await donutTop(previousShare)).toBe(previousDonutTop);
    await expect(previousShare.getByTitle("≥ 1,500,000 Token")).toHaveCount(2);
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
  const now = new Date();
  await page.clock.install({ time: now });
  const state = await reviewFixture(page);
  state.empty = true;
  await page.goto("/");
  const panel = page.getByRole("region", { name: "今日 Key 请求汇总" });
  await expect(panel.getByText("暂无活跃 Key", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("region", { name: "今日 Key 用量占比" }),
  ).toContainText("今日暂无活跃 Key");
  await expect(
    panel.getByRole("textbox", { name: "Key 展示范围" }),
  ).toHaveCount(0);
  await expect(panel.getByText("全部", { exact: true })).toHaveCount(0);
  await page.clock.setFixedTime(new Date(now.getTime() + 86400000));
  await page.clock.runFor(15000);
  await expect(panel.getByText(/旧业务日快照/)).toBeVisible();
  const previousShare = page.getByRole("region", {
    name: "Key 用量占比",
    exact: true,
  });
  await expect(previousShare).toContainText("该业务日暂无活跃 Key");
  await expect(previousShare).toContainText(now.toISOString().slice(0, 10));
  await expect(page.getByText("今日暂无活跃 Key")).toHaveCount(0);
});

for (const width of [1440, 390]) {
  test(`opens today's pre-admission rejections using the server business day at ${width}px`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 950 });
    const state = await reviewFixture(page);
    state.alerts = 0;
    state.keys.splice(1);
    const start = Date.parse("2026-11-09T16:00:00Z") / 1000;
    const meta = { timezone: "UTC+08:00", businessDay: { offsetMinutes: 480 } };
    const empty = {
      inputTokens: null,
      outputTokens: null,
      cachedTokens: null,
      images: null,
      estimatedMicros: null,
    };
    await page.route("**/api/usage/daily?*", (route) =>
      route.fulfill({
        json: {
          ...meta,
          days: 7,
          buckets: [
            {
              atUnixSeconds: start,
              requests: 0,
              recordedRejections: 2,
              succeeded: 0,
              failed: 0,
              cancelled: 0,
              inFlight: 0,
              failures: {},
              metrics: empty,
            },
          ],
        },
      }),
    );
    await page.route("**/api/usage/options", (route) =>
      route.fulfill({
        json: {
          ...meta,
          keys: ["alpha"],
          models: [],
          failures: ["invalid_request"],
        },
      }),
    );
    let requireFilters = false;
    let failReturn = false;
    await page.route("**/api/usage?*", (route) => {
      const params = new URL(route.request().url()).searchParams;
      expect(params.get("start")).toBe(String(start));
      expect(params.get("end")).toBe(String(start + 86400));
      expect(params.get("rejectedOnly")).toBe("true");
      const group = params.get("rejectionGroup");
      const secondPage = params.has("after");
      if (requireFilters) {
        expect(params.get("key")).toBe("alpha");
        expect(params.get("model")).toBe("synthetic-text");
      }
      if (failReturn && !group && secondPage) {
        failReturn = false;
        return route.fulfill({
          status: 503,
          json: { error: { code: "synthetic_failure" } },
        });
      }
      const counts = [
        {
          failure: "invalid_request",
          reason: "backend_parameter_temperature",
          count: 1,
        },
        { failure: "invalid_request", reason: null, count: 1 },
      ].filter(
        ({ failure, reason }) =>
          !group || group === `${failure}:${reason ?? "unrecorded"}`,
      );
      const report = reportFixture();
      const row = {
        ...report.rows[0],
        kind: "rejected",
        state: null,
        outcome: "failed",
        failure: "invalid_request",
        atUnixSeconds: start,
        metrics: empty,
        completeness: null,
      };
      return route.fulfill({
        json: {
          ...report,
          ...meta,
          startUnixSeconds: start,
          endUnixSeconds: start + 86400,
          totals: {
            ...report.totals,
            admitted: 0,
            recordedRejections: counts.length,
            inFlight: 0,
            unknown: 0,
            complete: 0,
            unavailable: 0,
            cancelled: 0,
            historicalWithoutTime: 0,
            unresolvedExposureMicros: "0",
            metrics: empty,
          },
          rejectionCounts: counts,
          buckets: Array.from({ length: 24 }, (_, i) => ({
            atUnixSeconds: start + i * 3600,
            admitted: 0,
            recordedRejections: i === 0 ? counts.length : 0,
            unresolved: 0,
          })),
          rows: group
            ? counts.map(({ reason }) => ({
                ...row,
                id: reason ? "specific" : "old",
                rejectionReason: reason,
              }))
            : secondPage
              ? [{ ...row, id: "old", requestID: "old" }]
              : [
                  {
                    ...row,
                    rejectionReason: "backend_parameter_temperature",
                    rejectionStage: "validation",
                  },
                ],
          nextCursor: !group && !secondPage ? "synthetic_cursor" : null,
        },
      });
    });
    await page.goto("/");
    await page.getByRole("link", { name: "查看今日拒绝 2条记录" }).click();
    await expect(page).toHaveURL(
      /start=2026-11-10&end=2026-11-10&rejectedOnly=true/,
    );
    const summary = page.getByRole("region", { name: "拒绝原因汇总" });
    await expect(summary).toContainText("上游不支持参数 temperature");
    await expect(summary).toContainText("子原因未记录");
    requireFilters = true;
    await page.evaluate(() => {
      const [path, query] = location.hash.split("?");
      const params = new URLSearchParams(query);
      params.set("key", "alpha");
      params.set("model", "synthetic-text");
      location.hash = `${path}?${params}`;
    });
    await expect(page.getByLabel("当前结果筛选")).toContainText(
      "模型 synthetic-text",
    );
    await page.getByRole("button", { name: "下一页" }).click();
    await expect(page).toHaveURL(/page=2/);
    const unknownReason = summary.getByRole("button", { name: /子原因未记录/ });
    await unknownReason.scrollIntoViewIfNeeded();
    const previousScroll = await page.evaluate(() => window.scrollY);
    await unknownReason.click();
    await expect(page).toHaveURL(
      /rejectionGroup=invalid_request%3Aunrecorded.*page=1/,
    );
    await expect(summary).not.toContainText("temperature");
    failReturn = true;
    const back = page.getByRole("button", { name: "返回全部拒绝" });
    await back.click();
    await expect(page.getByText(/第 2 页读取失败/)).toBeVisible();
    await back.click();
    await expect(page).toHaveURL(/page=2/);
    await expect(summary).toContainText("temperature");
    await expect
      .poll(() => page.evaluate(() => window.scrollY))
      .toBeCloseTo(previousScroll, 0);
    await summary.getByRole("button", { name: /temperature/ }).click();
    await expect(page).toHaveURL(
      /rejectionGroup=invalid_request%3Abackend_parameter_temperature/,
    );
    await expect(summary).not.toContainText("子原因未记录");
    await page.evaluate(() => {
      location.hash = "#/";
    });
    await expect(
      page.getByRole("link", { name: "查看今日拒绝 2条记录" }),
    ).toBeVisible();
    await page.goBack();
    await expect(page).toHaveURL(
      /rejectionGroup=invalid_request%3Abackend_parameter_temperature/,
    );
    await back.click();
    await expect(page).toHaveURL(/page=2/);
    await expect(summary).toContainText("子原因未记录");
    await expect
      .poll(() => page.evaluate(() => window.scrollY))
      .toBeCloseTo(previousScroll, 0);
    await expectNoHorizontalOverflow(page);
  });
}
