import { expect, test } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";

for (const width of [1440, 390]) {
  test(`device authorization success, enable, switch, cancel and expiry at ${width}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: width === 1440 ? 900 : 844 });
    await page.clock.install();
    const account = {
      id: "synthetic-device-account",
      revision: 1,
      credentialVersion: 1,
      mode: "disabled",
      authorization: "ready",
      createdAtUnixSeconds: 1,
    };
    let created = false,
      enabled = 0,
      deleted = 0,
      starts = 0;
    let scenario: "success" | "unavailable" | "pending" | "expiry" = "success";
    let method = "device";
    await page.route("**/api/**", async (route) => {
      const request = route.request(),
        path = new URL(request.url()).pathname;
      if (path === "/api/session")
        return route.fulfill({
          json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
        });
      if (path === "/api/accounts")
        return route.fulfill({
          json: { accounts: created ? [account] : [], nextCursor: null },
        });
      if (path === "/api/accounts/authorization") {
        starts++;
        method = request.postDataJSON().method;
        if (method === "callback")
          return route.fulfill({
            json: {
              flowID: "callback-flow",
              method,
              authorizationURL:
                "https://auth.openai.com/oauth/authorize?state=synthetic",
              expiresInSeconds: 600,
            },
          });
        return route.fulfill({
          json: {
            flowID: "device-flow-" + starts,
            method,
            expiresInSeconds: scenario === "expiry" ? 2 : 900,
            ...(scenario === "unavailable"
              ? { failureCode: "device_code_unavailable" }
              : {
                  userCode: "SYNTH-CODE",
                  verificationURL: "https://auth.openai.com/codex/device",
                  intervalSeconds: 3,
                }),
          },
        });
      }
      if (path.startsWith("/api/accounts/authorization/")) {
        if (request.method() === "DELETE") {
          deleted++;
          return route.fulfill({ json: { discarded: true } });
        }
        if (scenario === "success") {
          created = true;
          return route.fulfill({
            json: {
              status: "completed",
              accountID: account.id,
              expiresInSeconds: 899,
            },
          });
        }
        return route.fulfill({
          json: {
            status: "pending",
            userCode: "SYNTH-CODE",
            expiresInSeconds: scenario === "expiry" ? 1 : 900,
          },
        });
      }
      if (
        path === "/api/accounts/" + account.id &&
        request.method() === "PUT"
      ) {
        expect(request.postDataJSON()).toEqual({
          revision: account.revision,
          mode: "enabled",
        });
        enabled++;
        account.mode = "enabled";
        account.revision++;
        return route.fulfill({ json: { account } });
      }
      return route.fulfill({ status: 404, json: {} });
    });
    await page.goto("/#/accounts");
    const begin = page.getByRole("button", {
      name: "发起账号授权",
      exact: true,
    });
    await begin.click();
    const dialog = page.getByRole("dialog", { name: "接入订阅账号" });
    await expect(dialog.getByLabel("设备码", { exact: true })).toHaveValue(
      "SYNTH-CODE",
    );
    await expect(
      dialog.getByRole("link", { name: "打开验证页面" }),
    ).toHaveAttribute("href", "https://auth.openai.com/codex/device");
    await expect(
      dialog.getByRole("button", { name: "复制设备码", exact: true }),
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await page.clock.runFor(1100);
    await expect(dialog).toContainText("授权已验证并保存，新账号默认禁用。");
    expect(enabled).toBe(0);
    await dialog.getByRole("button", { name: "启用", exact: true }).click();
    await expect(dialog).toContainText("账号已启用。");
    expect(enabled).toBe(1);
    await dialog.getByRole("button", { name: "关闭授权结果" }).click();
    scenario = "unavailable";
    await begin.click();
    await expect(dialog).toContainText("ChatGPT 安全设置");
    await dialog.getByRole("button", { name: "改用浏览器回调方式" }).click();
    await expect(
      dialog.getByLabel("2. 粘贴完整回调地址", { exact: true }),
    ).toBeVisible();
    expect(method).toBe("callback");
    await dialog.getByRole("button", { name: "取消本次授权" }).click();
    scenario = "pending";
    await begin.click();
    await expect(dialog.getByLabel("设备码", { exact: true })).toBeVisible();
    const beforeCancel = deleted;
    await dialog.getByRole("button", { name: "关闭", exact: true }).click();
    await expect(dialog).not.toBeVisible();
    await expect.poll(() => deleted).toBe(beforeCancel + 1);
    scenario = "expiry";
    await begin.click();
    await expect(dialog.getByLabel("设备码", { exact: true })).toBeVisible();
    await page.clock.runFor(2500);
    await expect(dialog).toContainText("授权流程已过期，请关闭后重新发起。");
    await expect(dialog.getByLabel("设备码", { exact: true })).toHaveCount(0);
    expect(starts).toBe(5);
    await expectNoHorizontalOverflow(page);
    await dialog.getByRole("button", { name: "关闭授权结果" }).click();
    expect(
      await page.evaluate(() => [localStorage.length, sessionStorage.length]),
    ).toEqual([0, 0]);
  });
}
