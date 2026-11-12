import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { expectNoHorizontalOverflow } from "./layout";
import { observationFixture } from "../../src/features/account-management/observation.test-data";
for (const width of [1920, 390]) {
  test(`account details prioritizes overview and keeps header and drafts at ${width}px`, async ({
    page,
  }) => {
    test.setTimeout(30_000);
    await reviewFixture(page);
    const observation = observationFixture();
    await page.route("**/api/accounts/*/observation", (route) =>
      route.fulfill({
        json: {
          ...observation,
          quota: {
            ...observation.quota,
            usageCredits: { balance: "12345.9876543210", unlimited: false },
          },
        },
      }),
    );
    const historyReads: string[] = [];
    const through = 1_800_000_000;
    await page.route("**/api/accounts/*/usage-credit-history?*", (route) => {
      const range = new URL(route.request().url()).searchParams.get("range")!;
      historyReads.push(range);
      return route.fulfill({
        json: {
          from: through - (range === "24h" ? 86400 : 604800),
          through,
          segments: [
            ...(range === "7d"
              ? [[{ at: through - 172800, balance: "13500" }]]
              : []),
            [
              { at: through - 1200, balance: "12345.9876" },
              { at: through - 900, balance: "12345.9876" },
            ],
            [
              { at: through - 300, balance: "12500" },
              { at: through, balance: "12400" },
            ],
          ],
        },
      });
    });
    await page.emulateMedia({ reducedMotion: "reduce" });
    let primingReads = 0,
      resetReads = 0;
    page.on("request", (request) => {
      if (request.url().includes("/reset-credits")) resetReads++;
    });
    await page.route("**/api/accounts/*/quota-priming", (route) => {
      primingReads++;
      return route.fulfill({
        json: {
          revision: 1,
          settings: {
            enabled: false,
            model: "synthetic-text",
            message: "hello",
          },
          models: ["synthetic-text"],
          defaultModel: "synthetic-text",
          lastAttemptAt: null,
          lastResult: null,
          attention: null,
        },
      });
    });
    await page.setViewportSize({ width, height: width === 1920 ? 1680 : 844 });
    await page.goto("/#/?account=synthetic-account-3");
    const drawer = page.getByRole("dialog", { name: "账号详情" });
    await expect(
      drawer.getByRole("tab", { name: "概览", exact: true }),
    ).toHaveAttribute("aria-selected", "true", { timeout: 10_000 });
    await expect(drawer.getByText("当前并发", { exact: true })).toBeVisible();
    await expect(drawer.getByText("5 小时额度", { exact: true })).toBeVisible();
    await expect(
      drawer.getByText("额外使用积分", { exact: true }),
    ).toBeVisible();
    await expect(drawer.getByText("12,345", { exact: true })).toBeVisible();
    expect(historyReads).toEqual([]);
    const toggle = drawer.getByRole("button", { name: "走势", exact: true });
    await toggle.click();
    const history = drawer.getByRole("region", { name: "积分余额走势" });
    const chart = history.getByRole("img", { name: "额外使用积分余额阶梯图" });
    await expect(chart).toBeVisible();
    await expect(chart.locator("path:not([aria-hidden])")).toHaveCount(2);
    expect(
      await chart
        .locator("path:not([aria-hidden])")
        .first()
        .evaluate((path) => (path as SVGPathElement).getBBox().height),
    ).toBe(0);
    await chart.focus();
    await chart.press("ArrowRight");
    await expect(history.getByText(/ · 12,345$/)).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await history.getByText("近 7 天", { exact: true }).click();
    await expect(chart.locator("circle")).toHaveCount(1);
    await chart.focus();
    await chart.press("ArrowRight");
    await expect(history.getByText(/ · 13,500$/)).toBeVisible();
    expect(historyReads).toEqual(["24h", "7d"]);
    await toggle.click();
    await expect(history).toHaveCount(0);
    expect(primingReads).toBe(0);
    expect(resetReads).toBe(0);
    if (width === 390) {
      await expect(
        drawer.getByRole("button", { name: "关闭", exact: true }),
      ).toBeInViewport();
      await expect(
        drawer.getByRole("tab", { name: "设置", exact: true }),
      ).toBeInViewport();
      await expectNoHorizontalOverflow(page);
      return;
    }
    await drawer.getByRole("tab", { name: "设置", exact: true }).click();
    await drawer
      .getByLabel("账号显示名", { exact: true })
      .fill("未保存的合成名称");
    await drawer.getByRole("tab", { name: "概览", exact: true }).click();
    await drawer.getByRole("tab", { name: "设置", exact: true }).click();
    await expect(drawer.getByLabel("账号显示名", { exact: true })).toHaveValue(
      "未保存的合成名称",
    );
    await drawer.getByRole("tab", { name: "自动化", exact: true }).click();
    await drawer
      .getByRole("button", { name: "空闲窗口预热", exact: true })
      .click();
    const message = drawer.getByLabel("预热消息", { exact: true });
    await expect(message).toHaveValue("hello");
    await message.fill("未保存的预热消息");
    await drawer
      .getByRole("button", { name: "空闲窗口预热", exact: true })
      .click();
    await drawer
      .getByRole("button", { name: "空闲窗口预热", exact: true })
      .click();
    await expect(message).toHaveValue("未保存的预热消息");
    await drawer.getByRole("tab", { name: "概览", exact: true }).click();
    await drawer.getByRole("tab", { name: "自动化", exact: true }).click();
    await expect(message).toHaveValue("未保存的预热消息");
    expect(primingReads).toBe(1);
    await drawer
      .getByRole("tabpanel", { name: "自动化", exact: true })
      .evaluate((el) => {
        el.scrollTop = el.scrollHeight;
      });
    await expect(
      drawer.getByText("账号详情", { exact: true }),
    ).toBeInViewport();
    await expect(
      drawer.getByRole("button", { name: "关闭", exact: true }),
    ).toBeInViewport();
    await expect(
      drawer.getByRole("tab", { name: "概览", exact: true }),
    ).toBeInViewport();
    await expectNoHorizontalOverflow(page);
  });
}
