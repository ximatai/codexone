import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
for (const width of [1440, 390]) {
  test(`reset credits: list, confirmation, all results and settings at ${width}px`, async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const fixture = await reviewFixture(page);
    fixture.accounts[0].displayName = "合成重置卡账号";
    const state = {
      revision: 1,
      settings: { autoUseBeforeExpiry: false, leadHours: 24 },
      pending: false,
      pendingCreditID: null as string | null,
      lastCode: null as string | null,
      lastAttemptAt: null as number | null,
    };
    const credit = {
      id: "synthetic-credit",
      type: "synthetic",
      status: "available",
      grantedAt: "2026-01-01T00:00:00Z",
      expiresAt: "2030-01-01T00:00:00Z",
      title: "合成限额重置卡",
      description: "合成测试卡片",
    };
    let code = "nothing_to_reset";
    const calls: Record<string, unknown>[] = [];
    await page.route("**/api/accounts/*/reset-credits**", async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (route.request().method() === "GET")
        return route.fulfill({
          json: path.endsWith("/state")
            ? state
            : {
                credits: [
                  credit,
                  {
                    ...credit,
                    id: "synthetic-no-expiry",
                    title: "无到期重置卡",
                    expiresAt: null,
                  },
                ],
                availableCount: 2,
                state,
              },
        });
      expect(route.request().headers()["x-codexone-csrf"]).toBeTruthy();
      const body = route.request().postDataJSON();
      calls.push(body);
      if (path.endsWith("/settings")) {
        expect(body.revision).toBe(state.revision);
        state.settings = {
          autoUseBeforeExpiry: body.autoUseBeforeExpiry,
          leadHours: body.leadHours,
        };
        state.revision++;
        fixture.accounts[0].revision = state.revision;
        return route.fulfill({ json: state });
      }
      state.pending = code === "unknown";
      state.pendingCreditID = state.pending ? credit.id : null;
      state.lastCode = code;
      state.lastAttemptAt = Math.floor(Date.now() / 1000);
      return route.fulfill({
        json: { code, windowsReset: code === "reset" ? 1 : 0 },
      });
    });
    await page.goto("/#/accounts?target=synthetic-account-0");
    const drawer = page.getByRole("dialog", { name: /账号详情/ });
    await expect(drawer.getByText(/上次读取可用 2 张/)).toBeVisible();
    await expect(drawer.getByText(/上游未提供到期时间/)).toBeAttached();
    await drawer.getByRole("button", { name: "使用合成限额重置卡" }).click();
    const confirm = page.getByRole("dialog", {
      name: "确认使用重置卡",
      exact: true,
    });
    await expect(
      confirm.getByText("合成限额重置卡", { exact: true }),
    ).toBeVisible();
    await expect(confirm.getByText(/到期：/)).toBeVisible();
    expect(calls).toHaveLength(0);
    await page.screenshot({
      animations: "disabled",
      path: testInfo.outputPath(`reset-confirm-${width}.png`),
    });
    await confirm.getByRole("button", { name: "取消", exact: true }).click();
    expect(calls).toHaveLength(0);
    for (const [result, message] of [
      ["nothing_to_reset", "当前没有可重置的用量，卡未消耗"],
      ["reset", "重置成功，已消耗一张重置卡"],
      ["no_credit", "没有可用的重置卡"],
      ["already_redeemed", "该操作已处理"],
      ["unknown", "使用结果尚未确认"],
    ]) {
      code = result;
      await drawer.getByRole("button", { name: "使用合成限额重置卡" }).click();
      await confirm
        .getByRole("button", { name: "确认使用", exact: true })
        .click();
      await expect(drawer.getByText(new RegExp(message)).first()).toBeVisible();
      await expect(
        drawer.getByRole("button", { name: "重新读取重置卡" }),
      ).toBeEnabled();
    }
    expect(calls.at(-1)).toEqual({ creditID: credit.id });
    await expect(
      drawer.getByRole("button", { name: "由提供者选择一张" }),
    ).toBeDisabled();
    code = "already_redeemed";
    await drawer.getByRole("button", { name: "核对上次操作" }).click();
    await page.getByRole("button", { name: "确认核对", exact: true }).click();
    await expect(
      drawer.getByRole("button", { name: "由提供者选择一张" }),
    ).toBeEnabled();
    expect(calls.at(-1)).toEqual({});
    await drawer.getByLabel("到期前自动使用", { exact: true }).check();
    await drawer.getByLabel("提前小时数", { exact: true }).fill("48");
    await drawer.getByRole("button", { name: "保存重置卡设置" }).click();
    await expect(drawer.getByText("重置卡自动使用设置已保存。")).toBeVisible();
    expect(state.settings).toEqual({
      autoUseBeforeExpiry: true,
      leadHours: 48,
    });
    await page.screenshot({
      animations: "disabled",
      path: testInfo.outputPath(`reset-settings-${width}.png`),
    });
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  });
}
