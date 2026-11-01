import { expect, test } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";

for (const width of [1440, 390]) {
  test(`authorization failure reasons and consumed callback at ${width}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: width === 1440 ? 900 : 844 });
    await page.clock.install();
    let code = "provider_rejected",
      method = "device",
      posts = 0;
    await page.route("**/api/**", async (route) => {
      const request = route.request(),
        path = new URL(request.url()).pathname;
      if (path === "/api/session")
        return route.fulfill({
          json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
        });
      if (path === "/api/accounts")
        return route.fulfill({ json: { accounts: [], nextCursor: null } });
      if (path === "/api/accounts/authorization") {
        method = request.postDataJSON().method;
        return route.fulfill({
          json:
            method === "device"
              ? {
                  flowID: "synthetic-flow",
                  method,
                  expiresInSeconds: 900,
                  userCode: "SYNTH-CODE",
                  verificationURL: "https://auth.openai.com/codex/device",
                  intervalSeconds: 3,
                }
              : {
                  flowID: "synthetic-flow",
                  method,
                  expiresInSeconds: 600,
                  authorizationURL:
                    "https://auth.openai.com/oauth/authorize?state=synthetic",
                },
        });
      }
      if (path === "/api/accounts/authorization/synthetic-flow") {
        if (request.method() === "DELETE")
          return route.fulfill({ json: { discarded: true } });
        if (request.method() === "POST") {
          posts++;
          return route.fulfill({
            status: 409,
            json: { error: { code: "account_conflict" } },
          });
        }
        return route.fulfill({
          json: { status: "failed", expiresInSeconds: 899, failureCode: code },
        });
      }
      return route.fulfill({ status: 404, json: {} });
    });
    await page.goto("/#/accounts");
    const begin = page.getByRole("button", {
      name: "发起账号授权",
      exact: true,
    });
    const dialog = page.getByRole("dialog", { name: "接入订阅账号" });
    for (const [failure, message] of [
      ["provider_rejected", "提供者拒绝了设备码授权请求"],
      ["exchange_failed", "授权码兑换失败"],
      ["identity_mismatch", "登录的 ChatGPT 账号与要重新授权的账号不一致"],
      ["verification_failed", "授权安全校验失败"],
      ["revision_conflict", "账号版本或状态已变化"],
      ["device_code_unavailable", "设备码登录暂不可用"],
      ["authorization_failed", "授权未能完成"],
      ["future_failure", "授权未能完成"],
    ]) {
      code = failure;
      await begin.click();
      await expect(dialog.getByLabel("设备码", { exact: true })).toHaveValue(
        "SYNTH-CODE",
      );
      await page.clock.runFor(1100);
      await expect(dialog).toContainText(message);
      await expect(dialog.getByLabel("设备码", { exact: true })).toHaveCount(0);
      await expectNoHorizontalOverflow(page);
      if (code === "identity_mismatch")
        await page.screenshot({
          path: `../artifacts/auth-failure-reasons/device-${width}.png`,
          animations: "disabled",
        });
      await dialog.getByRole("button", { name: "关闭授权结果" }).click();
    }
    await begin.click();
    await dialog.getByRole("button", { name: "改用浏览器回调方式" }).click();
    code = "identity_mismatch";
    await dialog
      .getByLabel("2. 粘贴完整回调地址", { exact: true })
      .fill(
        "http://localhost:1455/auth/callback?state=synthetic&code=synthetic",
      );
    await dialog.getByRole("button", { name: "3. 验证并保存" }).click();
    await expect(dialog).toContainText(
      "登录的 ChatGPT 账号与要重新授权的账号不一致",
    );
    await expect(
      dialog.getByLabel("2. 粘贴完整回调地址", { exact: true }),
    ).toHaveCount(0);
    await expectNoHorizontalOverflow(page);
    await page.screenshot({
      path: `../artifacts/auth-failure-reasons/callback-${width}.png`,
      animations: "disabled",
    });
    expect(posts).toBe(1);
    await dialog.getByRole("button", { name: "关闭授权结果" }).click();
    expect(
      await page.evaluate(() => [localStorage.length, sessionStorage.length]),
    ).toEqual([0, 0]);
  });
}
