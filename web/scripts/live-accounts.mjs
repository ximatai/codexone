import { openChrome } from "./browser.mjs";
import { expect } from "@playwright/test";
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
const adminPort = Number(process.argv[2]), oauthPort = Number(process.argv[3]);
const output = resolve(process.argv[4]);
const rust = process.argv.includes("--rust");
assert([adminPort, oauthPort].every(port => Number.isInteger(port) && port > 0 && port <= 65535));
let input = "";
for await (const chunk of process.stdin) { input += chunk; assert(input.length < 4096); }
const { credential } = JSON.parse(input);
const origin = `http://127.0.0.1:${adminPort}`, oauthOrigin = `http://127.0.0.1:${oauthPort}`;
let browser, page, stage = "launch";
const secrets = [credential];
async function fixture(value) {
  const response = await fetch(oauthOrigin + "/__fixture", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value) });
  assert(response.ok);
}
async function admin(path = "/api/accounts", method = "GET", body) {
  const response = await fetch(origin + path, { method, headers: { Authorization: "Bearer " + credential, "Content-Type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
  assert(response.ok, "Synthetic headless management failed");
  return response.json();
}
async function staleWrite(path, body) {
  const response = await fetch(origin + path, {
    method: "PUT",
    headers: {
      Authorization: "Bearer " + credential,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "revision_conflict");
}
function putResponse(path) {
  return page.waitForResponse(
    (response) =>
      response.request().method() === "PUT" &&
      new URL(response.url()).pathname === path,
  );
}
async function checkRustSettings(id) {
  const prefix = "/api/accounts/" + id;
  const details = page.getByRole("dialog", { name: /^账号详情/ });
  await page
    .getByRole("button", { name: "额度与健康详情", exact: true })
    .click();
  await page.getByRole("tab", { name: "设置", exact: true }).click();
  const name = page.getByLabel("账号显示名", { exact: true });
  await name.fill("Synthetic subscriber");
  await page.getByRole("button", { name: "保存显示名", exact: true }).click();
  await expect(page.getByText("显示名已更新。", { exact: true })).toBeVisible();
  assert.equal((await admin()).accounts[0].displayName, "Synthetic subscriber");
  await details.getByRole("button", { name: "关闭", exact: true }).click();

  const resetPath = prefix + "/reset-credits";
  const resetState = await admin(resetPath + "/state");
  const legacy = await admin(resetPath + "/settings", "PUT", {
    revision: resetState.revision,
    autoUseBeforeExpiry: false,
    leadHours: 2,
  });
  assert.equal(legacy.settings.leadMinutes, 120);
  assert.equal(legacy.settings.retryCount, 3);
  await page
    .getByRole("button", { name: "额度与健康详情", exact: true })
    .click();
  await page.getByRole("tab", { name: "自动化", exact: true }).click();
  await page.getByRole("button", { name: "重置卡与到期前自动使用" }).click();
  const lead = page.getByLabel("提前量", { exact: true });
  await expect(lead).toHaveValue("2");
  await page.getByLabel("提前量单位", { exact: true }).selectOption("minutes");
  await lead.fill("35");
  const retries = page.getByLabel("失败后重试次数", { exact: true });
  await retries.fill("2");
  const resetResponse = putResponse(resetPath + "/settings");
  await page.getByRole("button", { name: "保存重置卡设置" }).click();
  const reset = await resetResponse;
  assert.equal(reset.status(), 200);
  await expect(
    page.getByText("重置卡自动使用设置已保存。", { exact: true }),
  ).toBeVisible();
  const readback = await admin(resetPath + "/state");
  assert.equal(readback.settings.leadMinutes, 35);
  assert.equal(readback.settings.retryCount, 2);
  await staleWrite(resetPath + "/settings", reset.request().postDataJSON());

  await page.getByRole("button", { name: "空闲窗口预热", exact: true }).click();
  const primingPath = prefix + "/quota-priming";
  const message = page.getByLabel("预热消息", { exact: true });
  await expect(message).toBeEnabled();
  await message.fill("Synthetic priming copy");
  const primingResponse = putResponse(primingPath);
  await page.getByRole("button", { name: "保存预热设置" }).click();
  const priming = await primingResponse;
  assert.equal(priming.status(), 200);
  await expect(
    page.getByText("空闲窗口预热设置已保存。", { exact: true }),
  ).toBeVisible();
  assert.equal(
    (await admin(primingPath)).settings.message,
    "Synthetic priming copy",
  );
  await staleWrite(primingPath, priming.request().postDataJSON());
  await details.getByRole("button", { name: "关闭", exact: true }).click();

  await page.getByRole("link", { name: "模型目录", exact: true }).click();
  const editRates = page.getByRole("button", { name: "编辑费率", exact: true });
  await editRates.click();
  const dialog = page.getByRole("dialog", { name: "编辑模型费率" });
  const input = dialog.getByLabel("输入费率（美元／百万 Token）", {
    exact: true,
  });
  await input.fill("1.25");
  const modelResponse = putResponse("/api/models/rates");
  await dialog.getByRole("button", { name: "保存", exact: true }).click();
  const model = await modelResponse;
  assert.equal(model.status(), 200);
  await expect(
    page.getByText("模型费率已保存。", { exact: true }),
  ).toBeVisible();
  await staleWrite("/api/models/rates", model.request().postDataJSON());
  await editRates.click();
  await expect(input).toHaveValue("1.25");
  await dialog.getByRole("button", { name: "取消", exact: true }).click();
}
async function checkRustKeyPolicy() {
  const { key } = await admin("/api/keys", "POST", {
    principal: "synthetic-client",
    models: ["synth-text"],
    limits: { tokens: null, active: 2 },
  });
  await page.goto(origin + "/#/keys");
  await page.getByRole("button", { name: "查看详情", exact: true }).click();
  const details = page.getByRole("dialog", { name: "密钥详情" });
  await details.getByText("本地治理限额", { exact: true }).click();
  await details
    .getByRole("checkbox", { name: "每日 Token 上限不限" })
    .uncheck();
  await details.getByLabel("每日 Token 上限", { exact: true }).fill("17");
  const saved = putResponse("/api/keys/" + key.id);
  await details.getByRole("button", { name: "保存修改", exact: true }).click();
  assert.equal((await saved).status(), 200);
  await expect(details).toBeHidden();
  const readback = (await admin("/api/keys")).keys.find(
    (entry) => entry.id === key.id,
  );
  assert.equal(readback.limits.tokens, 17);
  assert.deepEqual(readback.models, ["synth-text"]);
}
async function checkRustFallback() {
  let liveSocket;
  let blocked = false;
  await page.routeWebSocket("**/api/overview/live", (ws) => {
    if (blocked) {
      ws.close({ code: 1011 });
      return;
    }
    liveSocket = ws;
    ws.connectToServer();
  });
  await page.getByRole("link", { name: /^服务概览/ }).click();
  const activity = page.locator("[data-live-mode]");
  await expect(activity).toHaveAttribute("data-live-mode", "live");
  await page
    .getByRole("button", { name: /查看.*额度趋势/ })
    .first()
    .click();
  await expect(page.getByRole("img", { name: /剩余额度走势/ })).toBeVisible();
  const poll = page.waitForResponse(
    (response) =>
      response.status() === 200 &&
      new URL(response.url()).pathname === "/api/usage/in-flight",
  );
  blocked = true;
  await liveSocket.close({ code: 1011 });
  const payload = await (await poll).json();
  assert.equal(typeof payload, "object");
  await expect(activity).toHaveAttribute("data-live-mode", "polling");
  await expect(
    page.getByText("Synthetic subscriber", { exact: true }).first(),
  ).toBeVisible();
}
async function capture(name) {
  const html = await page.content();
  assert(secrets.every(secret => !html.includes(secret)), "Private material in rendered DOM");
  await page.screenshot({ path: resolve(output, name), fullPage: true, animations: "disabled", mask: [page.locator('input[type="password"]'), page.locator('a[href*="oauth/authorize"]')] });
}
async function finishAuthorization(buttonName, method = "callback") {
  const prefix = stage;
  stage = prefix + "-start";
  await page.getByRole("button", { name: buttonName, exact: true }).click();
  if (method === "device") {
    await expect(page.getByLabel("设备码", { exact: true })).toHaveValue("SYNTH-CODE");
    await capture("device-desktop.png");
    const popupPromise = page.waitForEvent("popup");
    await page.getByRole("link", { name: "打开验证页面" }).click();
    const popup = await popupPromise;
    await popup.getByRole("link", { name: "Approve synthetic device" }).click();
    await expect(popup.getByRole("heading", { name: "Device approved" })).toBeVisible();
    await popup.close();
    await expect(page.getByText("授权已验证并保存，新账号默认禁用。", { exact: true }).first()).toBeVisible();
    await page.getByRole("button", { name: "关闭授权结果" }).click();
    return;
  }
  await page.getByRole("button", { name: "改用浏览器回调方式" }).click();
  stage = prefix + "-popup";
  const popupPromise = page.waitForEvent("popup");
  await page.getByRole("link", { name: "1. 在新窗口打开授权页面" }).click();
  const popup = await popupPromise;
  await expect(popup.getByRole("heading", { name: "合成订阅授权" })).toBeVisible();
  stage = prefix + "-callback";
  const url = new URL(popup.url());
  const callback = await popup.getByRole("link", { name: "复制合成回调地址" }).getAttribute("href");
  assert(callback.startsWith("http://localhost:1455/auth/callback?"));
  secrets.push(callback);
  await fixture({ nonce: url.searchParams.get("nonce"), challenge: url.searchParams.get("code_challenge"), mode: "success" });
  await popup.close(); // Never visit the real local callback port or a personal Codex listener.
  stage = prefix + "-paste";
  await page.getByLabel("2. 粘贴完整回调地址", { exact: true }).fill(callback);
  stage = prefix + "-save";
  await page.getByRole("button", { name: "3. 验证并保存", exact: true }).click();
  stage = prefix + "-confirmed";
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
  await expect(page.locator('[role="dialog"]')).toHaveCount(0);
  await expect(page.getByRole("button", { name: "重新读取账号", exact: true })).toBeEnabled();
}
async function checkRustAccount() {
  stage = "rust-cancel";
  const authorize = page.getByRole("button", {
    name: "发起账号授权",
    exact: true,
  });
  await authorize.click();
  await expect(page.getByLabel("设备码", { exact: true })).toHaveValue(
    "SYNTH-CODE",
  );
  const cancelled = page.waitForResponse(
    (response) =>
      response.request().method() === "DELETE" &&
      /^\/api\/accounts\/authorization\/[^/]+$/.test(
        new URL(response.url()).pathname,
      ),
  );
  await page.getByRole("button", { name: "取消本次授权", exact: true }).click();
  assert.equal((await cancelled).status(), 200);
  assert.equal((await admin()).accounts.length, 0);

  stage = "rust-device";
  await finishAuthorization("发起账号授权", "device");
  await expect(
    page.getByRole("switch", { name: "已停用", exact: true }),
  ).not.toBeChecked();
  const first = (await admin()).accounts[0];
  assert.equal(first.mode, "disabled");
  assert.equal(first.credentialVersion, 1);
  const prefix = "/api/accounts/" + first.id;
  const details = page.getByRole("dialog", { name: /^账号详情/ });
  const showDetails = page.getByRole("button", {
    name: "额度与健康详情",
    exact: true,
  });
  const showSettings = page.getByRole("tab", { name: "设置", exact: true });
  const refresh = page.getByRole("button", {
    name: "刷新登录凭证",
    exact: true,
  });

  stage = "rust-refresh";
  await showDetails.click();
  await showSettings.click();
  await refresh.click();
  await expect
    .poll(async () => (await admin()).accounts[0].credentialVersion)
    .toBe(2);
  await expect(refresh).toBeEnabled();
  await fixture({ mode: "reject" });
  await refresh.click();
  await expect
    .poll(async () => (await admin()).accounts[0].authorization)
    .toBe("requires_auth");
  await expect(
    page.getByRole("button", { name: "重新登录授权", exact: true }),
  ).toBeEnabled();
  stage = "rust-callback";
  await finishAuthorization("重新登录授权");
  const reauthorized = (await admin()).accounts[0];
  assert.equal(reauthorized.id, first.id);
  assert.equal(reauthorized.mode, "disabled");
  assert.equal(reauthorized.credentialVersion, 3);

  stage = "rust-observe";
  if (!(await details.isVisible())) await showDetails.click();
  await page.getByRole("tab", { name: "概览", exact: true }).click();
  const observe = page.getByRole("button", { name: "更新额度", exact: true });
  const unauthorizedObserve = await page.evaluate(
    async (path) =>
      (
        await fetch(path, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        })
      ).status,
    prefix + "/observe",
  );
  assert.equal(unauthorizedObserve, 403);
  await observe.click();
  await expect(
    page.getByText("额度观测已更新。", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("剩余 75%", { exact: true }).first(),
  ).toBeVisible();
  const result = await admin(prefix + "/observation");
  assert.equal(result.quota.usageCredits.balance, "12.500");
  const summary = (await admin()).accounts[0].observability;
  assert.equal(summary.quota.usageCredits, undefined);
  assert.equal(summary.quota.limits.length, 1);
  assert.equal(result.quota.limits.length, 2);

  stage = "rust-credit-history";
  const history = (range) =>
    page.waitForResponse(
      (response) =>
        response.status() === 200 &&
        new URL(response.url()).pathname === prefix + "/usage-credit-history" &&
        new URL(response.url()).searchParams.get("range") === range,
    );
  const day = history("24h");
  await page.getByRole("button", { name: "走势", exact: true }).click();
  const graph = page.getByRole("img", { name: "额外使用积分余额阶梯图" });
  assert.equal((await day).headers()["cache-control"], "no-store");
  await expect(graph).toBeVisible();
  const week = history("7d");
  await page.getByText("近 7 天", { exact: true }).click();
  assert.equal((await (await week).json()).segments[0][0].balance, "12.500");
  await expect(graph).toBeVisible();

  stage = "rust-observe-failure";
  await fixture({ quota_mode: "fail" });
  await observe.click();
  await expect(
    page.getByRole("status").filter({ hasText: "本次额度读取失败" }),
  ).toBeVisible();
  await expect(
    page.getByText("剩余 75%", { exact: true }).first(),
  ).toBeVisible();
  assert.equal(
    (await admin(prefix + "/observation")).quota.observedAtUnixSeconds,
    result.quota.observedAtUnixSeconds,
  );
  await fixture({ quota_mode: "ok" });
  await observe.click();
  await expect(
    page.getByText("额度观测已更新。", { exact: true }),
  ).toBeVisible();
  await details.getByRole("button", { name: "关闭", exact: true }).click();

  stage = "rust-settings";
  await checkRustSettings(first.id);
  stage = "rust-key-policy";
  await checkRustKeyPolicy();
  stage = "rust-live-fallback";
  await checkRustFallback();

  stage = "rust-refresh-timeout";
  await page.getByRole("link", { name: "订阅账号", exact: true }).click();
  await showDetails.click();
  await showSettings.click();
  await fixture({ mode: "timeout" });
  const timeout = page.waitForResponse(
    (response) =>
      response.request().method() === "POST" &&
      new URL(response.url()).pathname === prefix + "/refresh",
    { timeout: 18_000 },
  );
  await refresh.click();
  const response = await timeout;
  assert.equal(response.status(), 503);
  assert.equal((await response.json()).error.code, "account_unavailable");
  await expect(
    page.getByRole("alert").filter({ hasText: "操作结果尚未确认" }),
  ).toBeVisible();
  await expect
    .poll(async () => (await admin()).accounts[0].authorization, { timeout: 18_000 })
    .toBe("auth_uncertain");
  const uncertain = (await admin()).accounts[0];
  assert.equal(uncertain.credentialVersion, 3);
}
async function checkSwiftAccount() {
  await capture("empty-desktop.png");
  stage = "cancel";
  await page.getByRole("button", { name: "发起账号授权", exact: true }).click();
  await page.getByRole("button", { name: "取消本次授权", exact: true }).click();
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "发起账号授权", exact: true })).toBeEnabled();
  stage = "authorize";
  await finishAuthorization("发起账号授权", "device");
  await expect(page.getByText("已禁用", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("授权有效", { exact: true }).first()).toBeVisible();
  await capture("account-desktop.png");
  let account = (await admin()).accounts[0];
  const id = account.id;
  await page.getByRole("button", { name: "额度与健康详情", exact: true }).click();
  await page.getByRole("tab", { name: "设置", exact: true }).click();
  stage = "replaced-session";
  assert.equal(await page.evaluate(async secret => (await fetch("/api/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: "admin", secret }) })).status, credential), 200);
  await page.getByRole("radio", { name: "启用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("管理会话已更新");
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await page.getByRole("button", { name: "额度与健康详情", exact: true }).click();
  await page.getByRole("tab", { name: "设置", exact: true }).click();
  await expect(page.getByRole("radio", { name: "启用", exact: true })).toBeEnabled();
  stage = "enable";
  await page.getByRole("radio", { name: "启用", exact: true }).click();
  await expect(page.getByRole("radio", { name: "启用", exact: true })).toBeChecked();
  account = (await admin()).accounts[0];
  assert.equal(account.mode, "enabled");
  await page.getByRole("dialog", { name: /^账号详情/ }).getByRole("button", { name: "关闭", exact: true }).click();
  stage = "replaced-flow-owner";
  await page.getByRole("button", { name: "发起账号授权", exact: true }).click();
  await page.getByRole("button", { name: "改用浏览器回调方式" }).click();
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "重新读取账号", exact: true })).toBeEnabled();
  assert.equal(await page.evaluate(async secret => (await fetch("/api/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username: "admin", secret }) })).status, credential), 200);
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
  await expect(page.getByText(/管理会话已更新/).first()).toBeVisible();
  await page.getByRole("button", { name: "额度与健康详情", exact: true }).click();
  await page.getByRole("tab", { name: "设置", exact: true }).click();
  stage = "conflict";
  await admin("/api/accounts/" + id, "PUT", { revision: account.revision, mode: "draining" });
  await page.getByRole("radio", { name: "禁用", exact: true }).click();
  await page.getByRole("button", { name: "确认禁用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("数据已被修改，请确认后重试");
  await expect(page.getByRole("radio", { name: "禁用", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("排空中", { exact: true }).first()).toBeVisible();
  stage = "unknown-write";
  account = (await admin()).accounts[0];
  await page.route("**/api/accounts/" + id, async route => {
    if (route.request().method() === "PUT") { await route.fetch(); await route.abort(); }
    else await route.continue();
  });
  await page.getByRole("radio", { name: "禁用", exact: true }).click();
  await page.getByRole("button", { name: "确认禁用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("操作结果尚未确认");
  await expect(page.getByRole("radio", { name: "禁用", exact: true })).toBeDisabled();
  await page.unroute("**/api/accounts/" + id);
  await page.route("**/api/accounts", route => route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: { code: "management_unavailable" } }) }));
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "账号读取失败" })).toBeVisible();
  await expect(page.getByRole("radio", { name: "禁用", exact: true })).toBeDisabled();
  await page.unroute("**/api/accounts");
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("已禁用", { exact: true }).first()).toBeVisible();
  assert.equal((await admin()).accounts[0].revision, account.revision + 1);
  stage = "rejected-refresh";
  await fixture({ mode: "reject" });
  await page.getByRole("button", { name: "刷新登录凭证", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("上游授权已失效");
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("需要重新授权", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "刷新登录凭证", exact: true })).toBeDisabled();
  await capture("reauthorize-desktop.png");
  stage = "reauthorize";
  await finishAuthorization("重新登录授权");
  await expect(page.getByText("授权有效", { exact: true }).first()).toBeVisible();
  account = (await admin()).accounts[0];
  assert.equal(account.id, id); assert.equal(account.credentialVersion, 2); assert.equal(account.mode, "disabled");
  await capture("reauthorized-desktop.png");
  stage = "quota-success";
  await page.getByRole("button", { name: "额度与健康详情", exact: true }).click();
  await expect(page.getByRole("button", { name: "更新额度", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "更新额度", exact: true }).click();
  await expect(page.getByText("额度观测已更新。", { exact: true })).toBeVisible();
  await expect(page.getByText("剩余 75%", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("progressbar", { name: "每周额度剩余比例", exact: true }).first()).toHaveAttribute("aria-valuenow", "55");
  const observed = (await admin()).accounts[0].observability.quota.observedAtUnixSeconds;
  await capture("quota-desktop.png");
  stage = "quota-failure-retains-value";
  await fixture({ quota_mode: "fail" });
  await page.getByRole("button", { name: "更新额度", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "本次额度读取失败" })).toContainText("本次额度读取失败");
  await expect(page.getByText("剩余 75%", { exact: true }).first()).toBeVisible();
  const failedQuota = (await admin()).accounts[0].observability.quota;
  assert.equal(failedQuota.observedAtUnixSeconds, observed);
  assert.equal(failedQuota.failure, "unavailable");
  await capture("quota-failure-desktop.png");
  stage = "quota-stale";
  await page.clock.fastForward(310_000);
  await expect(page.getByText(/套餐额度观测已陈旧/).first()).toBeVisible();
  await fixture({ quota_mode: "ok" });
  await page.getByRole("button", { name: "更新额度", exact: true }).click();
  await expect(page.getByText("额度观测已更新。", { exact: true })).toBeVisible();
  await expect(page.getByText("额度观测已陈旧", { exact: true })).toHaveCount(0);
  await expect(page.getByText("剩余 75%", { exact: true }).first()).toBeVisible();
  stage = "quota-restricted-without-percentages";
  await fixture({ quota_mode: "restricted" });
  await page.getByRole("button", { name: "更新额度", exact: true }).click();
  await expect(page.getByText("上游允许使用：否 · 已达窗口限额：是", { exact: true })).toBeVisible();
  await expect(page.getByText("上游额度报告受限，请查看窗口详情", { exact: true })).toBeVisible();
  await expect(page.getByText("剩余 75%", { exact: true }).first()).toHaveCount(0);
  await capture("quota-restricted-desktop.png");
  await page.getByRole("dialog", { name: /^账号详情/ }).getByRole("button", { name: "关闭", exact: true }).click();
  stage = "logout";
  await page.route("**/api/session", route => route.request().method() === "DELETE" ? route.abort() : route.continue());
  await page.getByRole("button", { name: "退出登录", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("登出尚未确认");
  await expect(page.getByRole("heading", { name: "登出状态待确认", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "重试登出", exact: true })).toBeEnabled();
  await expect(page.getByText("授权有效", { exact: true }).first()).toHaveCount(0);
  await expect(page.getByRole("button", { name: "重新读取账号", exact: true })).toHaveCount(0);
  await expect(page.getByRole("radio", { name: "启用", exact: true })).toHaveCount(0);
  await page.unroute("**/api/session");
  await page.getByRole("button", { name: "重试登出", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  stage = "committed-logout-response-loss";
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
  await expect(page.getByText("授权有效", { exact: true }).first()).toBeVisible();
  await page.route("**/api/session", async route => {
    if (route.request().method() === "DELETE") { await route.fetch(); await route.abort(); }
    else await route.continue();
  });
  await page.getByRole("button", { name: "退出登录", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("登出尚未确认");
  await expect(page.getByRole("button", { name: "重试登出", exact: true })).toBeEnabled();
  await page.unroute("**/api/session");
  await page.getByRole("button", { name: "重试登出", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  stage = "expired-detail-clears-page-and-late-flow";
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
  await expect(page.getByText("授权有效", { exact: true }).first()).toBeVisible();
  let releaseFlow, markPrepared, markDelivered;
  const flowHeld = new Promise(resolve => { releaseFlow = resolve; });
  const flowPrepared = new Promise(resolve => { markPrepared = resolve; });
  const flowDelivered = new Promise(resolve => { markDelivered = resolve; });
  await page.route("**/api/accounts/authorization", async route => {
    const response = await route.fetch(); markPrepared(); await flowHeld;
    await route.fulfill({ response }); markDelivered();
  });
  await page.getByRole("button", { name: "发起账号授权", exact: true }).click();
  stage = "expired-detail-flow-response-held";
  await flowPrepared;
  stage = "expired-detail-revoke-session";
  await page.evaluate(async () => { const { csrf } = await (await fetch("/api/session")).json(); await fetch("/api/session", { method: "DELETE", headers: { "X-CodexOne-CSRF": csrf } }); });
  stage = "expired-detail-wait-for-clear";
  await page.getByRole("button", { name: "额度与健康详情", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  await expect(page.getByText("授权有效", { exact: true }).first()).toHaveCount(0);
  await expect(page.getByRole("button", { name: "额度与健康详情", exact: true })).toHaveCount(0);
  stage = "expired-detail-release-old-response";
  releaseFlow(); await flowDelivered; await page.unroute("**/api/accounts/authorization");
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
  await expect(page.getByText("授权有效", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "发起账号授权", exact: true })).toBeEnabled();
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
}
try {
  browser = await openChrome();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    return url.origin === origin || (url.origin === oauthOrigin && ["/oauth/authorize", "/codex/device", "/__approve"].includes(url.pathname) && route.request().method() === "GET") ? route.continue() : route.abort();
  });
  page = await context.newPage();
  await page.clock.install();
  const errors = [];
  page.on("pageerror", () => errors.push("page error"));
  page.on("console", entry => { if (/content security policy|refused to execute|refused to apply/i.test(entry.text())) errors.push("CSP rejection"); });
  await mkdir(output, { recursive: true });
  stage = "login";
  await page.goto(origin);
  await page.getByRole("link", { name: "订阅账号", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  await capture("login-desktop.png");
  await page.getByLabel("管理员凭证", { exact: true }).fill("synthetic-wrong-admin");
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("管理员凭证无效");
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
  await expect(page.getByRole("button", { name: "发起账号授权", exact: true })).toBeEnabled();
  if (rust) {
    page.setDefaultTimeout(8_000);
    await checkRustAccount();
  } else await checkSwiftAccount();
  assert.deepEqual(await page.evaluate(() => [localStorage.length, sessionStorage.length]), [0, 0]);
  assert.equal(await page.locator("style").count(), 0);
  assert.deepEqual(errors, []);
  if (rust) {
    console.log(
      "PASS: Rust device cancel and approval, callback reauthorization, refresh success/rejection/timeout, observation and history, settings readback/CAS, key policy and live to HTTP",
    );
  } else console.log("PASS: actual Chrome account UI: login, cancel/code+PKCE, default disabled, enable/CAS, unknown write/read lock, rejected refresh/reauthorization, session replacement/logout retry; passive quota GET, failure retention/staleness/recovery; private storage and large-screen captures");
} catch (error) {
  console.error("Account assertion line=" + (error?.stack?.match(/live-accounts\.mjs:(\d+)/)?.[1] ?? "unknown") + "; class=" + error?.name);
  await page?.screenshot({ path: resolve(output, "failure-desktop.png"), fullPage: true, animations: "disabled", mask: [page.locator('input[type="password"]'), page.locator('a[href*="oauth/authorize"]')] }).catch(() => {});
  console.error(`Browser account check failed at stage: ${stage}; private diagnostics excluded.`);
  process.exitCode = 1;
} finally { await browser?.close(); }
