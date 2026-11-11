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
