import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
for (const width of [1440, 390]) {
  test(`quota priming settings at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const fixture = await reviewFixture(page);
    const state = {
      revision: 1,
      settings: { enabled: false, model: "synthetic-cheap", message: "hello" },
      models: ["synthetic-cheap", "synthetic-other"],
      defaultModel: "synthetic-cheap",
      lastAttemptAt: 1_800_000_000,
      lastResult: "success",
      attention: null,
    };
    const calls: unknown[] = [];
    await page.route("**/api/accounts/*/quota-priming", async (route) => {
      if (route.request().method() === "PUT") {
        const body = route.request().postDataJSON();
        calls.push(body);
        expect(route.request().headers()["x-codexone-csrf"]).toBeTruthy();
        expect(body.revision).toBe(state.revision);
        state.settings = {
          enabled: body.enabled,
          model: body.model,
          message: body.message,
        };
        state.revision++;
        fixture.accounts[0].revision = state.revision;
      }
      return route.fulfill({ json: state });
    });
    await page.goto("/#/accounts?target=synthetic-account-0");
    const section = page.getByRole("region", {
      name: "空闲窗口预热",
      exact: true,
    });
    await expect(section.getByLabel("预热消息", { exact: true })).toHaveValue(
      "hello",
    );
    await expect(
      section.getByLabel("自动预热空闲窗口", { exact: true }),
    ).not.toBeChecked();
    await section.getByLabel("自动预热空闲窗口", { exact: true }).check();
    await section
      .getByLabel("预热模型", { exact: true })
      .selectOption("synthetic-other");
    await section.getByLabel("预热消息", { exact: true }).fill("a".repeat(201));
    await expect(
      section.getByRole("button", { name: "保存预热设置" }),
    ).toBeDisabled();
    await section
      .getByLabel("预热消息", { exact: true })
      .fill("你好，合成消息");
    await expect(section.getByText("7 / 200 字符")).toBeVisible();
    await page.screenshot({
      animations: "disabled",
      path: testInfo.outputPath(`priming-form-${width}.png`),
    });
    await section.getByRole("button", { name: "保存预热设置" }).click();
    await expect(page.getByText("空闲窗口预热设置已保存。")).toBeVisible();
    expect(calls).toEqual([
      {
        revision: 1,
        enabled: true,
        model: "synthetic-other",
        message: "你好，合成消息",
      },
    ]);
    await expect(section.getByLabel("预热消息", { exact: true })).toHaveValue(
      "你好，合成消息",
    );
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  });
}
