import { chromium, expect } from "@playwright/test";
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
const adminPort = Number(process.argv[2]), oauthPort = Number(process.argv[3]);
const output = resolve(process.argv[4]);
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
async function capture(name) {
  const html = await page.content();
  assert(secrets.every(secret => !html.includes(secret)), "Private material in rendered DOM");
  await page.screenshot({ path: resolve(output, name), fullPage: true, mask: [page.locator('input[type="password"]'), page.locator('a[href*="oauth/authorize"]')] });
}
async function finishAuthorization(buttonName) {
  const prefix = stage;
  stage = prefix + "-start";
  await page.getByRole("button", { name: buttonName, exact: true }).click();
  stage = prefix + "-popup";
  const popupPromise = page.waitForEvent("popup");
  await page.getByRole("link", { name: "在新窗口打开授权页面" }).click();
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
  await page.getByRole("button", { name: "验证并保存", exact: true }).click();
  stage = prefix + "-confirmed";
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "重新读取账号", exact: true })).toBeEnabled();
}
try {
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    return url.origin === origin || (url.origin === oauthOrigin && url.pathname === "/oauth/authorize" && route.request().method() === "GET") ? route.continue() : route.abort();
  });
  page = await context.newPage();
  const errors = [];
  page.on("pageerror", () => errors.push("page error"));
  page.on("console", entry => { if (/content security policy|refused to execute|refused to apply/i.test(entry.text())) errors.push("CSP rejection"); });
  await mkdir(output, { recursive: true });
  stage = "login";
  await page.goto(origin);
  await page.getByRole("button", { name: "订阅账号", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  await capture("login-desktop.png");
  await page.getByLabel("管理员凭证", { exact: true }).fill("synthetic-wrong-admin");
  await page.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("登录失败");
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录", exact: true }).click();
  await expect(page.getByRole("button", { name: "发起账号授权", exact: true })).toBeEnabled();
  await capture("empty-desktop.png");
  stage = "cancel";
  await page.getByRole("button", { name: "发起账号授权", exact: true }).click();
  await page.getByRole("button", { name: "取消本次授权", exact: true }).click();
  await expect(page.getByLabel("2. 粘贴完整回调地址", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "发起账号授权", exact: true })).toBeEnabled();
  stage = "authorize";
  await finishAuthorization("发起账号授权");
  await expect(page.getByText("已禁用", { exact: true })).toBeVisible();
  await expect(page.getByText("授权有效", { exact: true })).toBeVisible();
  await capture("account-desktop.png");
  let account = (await admin()).accounts[0];
  const id = account.id;
  stage = "enable";
  await page.getByRole("button", { name: "启用", exact: true }).click();
  await expect(page.getByText("允许使用", { exact: true })).toBeVisible();
  account = (await admin()).accounts[0];
  assert.equal(account.mode, "enabled");
  stage = "conflict";
  await admin("/api/accounts/" + id, "PUT", { revision: account.revision, mode: "draining" });
  await page.getByRole("button", { name: "禁用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("状态已变化");
  await expect(page.getByRole("button", { name: "禁用", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("排空中", { exact: true })).toBeVisible();
  stage = "unknown-write";
  account = (await admin()).accounts[0];
  await page.route("**/api/accounts/" + id, async route => {
    if (route.request().method() === "PUT") { await route.fetch(); await route.abort(); }
    else await route.continue();
  });
  await page.getByRole("button", { name: "禁用", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("操作结果未确认");
  await expect(page.getByRole("button", { name: "禁用", exact: true })).toBeDisabled();
  await page.unroute("**/api/accounts/" + id);
  await page.route("**/api/accounts", route => route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: { code: "management_unavailable" } }) }));
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("账号读取失败");
  await expect(page.getByRole("button", { name: "禁用", exact: true })).toBeDisabled();
  await page.unroute("**/api/accounts");
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("已禁用", { exact: true })).toBeVisible();
  assert.equal((await admin()).accounts[0].revision, account.revision + 1);
  stage = "rejected-refresh";
  await fixture({ mode: "reject" });
  await page.getByRole("button", { name: "刷新授权", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("上游授权已失效");
  await page.getByRole("button", { name: "重新读取账号", exact: true }).click();
  await expect(page.getByText("需要重新授权", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "刷新授权", exact: true })).toBeDisabled();
  await capture("reauthorize-desktop.png");
  stage = "reauthorize";
  await finishAuthorization("重新授权");
  await expect(page.getByText("授权有效", { exact: true })).toBeVisible();
  account = (await admin()).accounts[0];
  assert.equal(account.id, id); assert.equal(account.credentialVersion, 2); assert.equal(account.mode, "disabled");
  await capture("reauthorized-desktop.png");
  stage = "logout";
  await page.getByRole("button", { name: "登出", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录", exact: true })).toBeVisible();
  assert.deepEqual(await page.evaluate(() => [localStorage.length, sessionStorage.length]), [0, 0]);
  assert.deepEqual(errors, []);
  console.log("PASS: actual Chrome account UI: login, cancel/code+PKCE, default disabled, enable/CAS, unknown write/read lock, rejected refresh/reauthorization, logout; private storage and large-screen captures");
} catch {
  await page?.screenshot({ path: resolve(output, "failure-desktop.png"), fullPage: true, mask: [page.locator('input[type="password"]'), page.locator('a[href*="oauth/authorize"]')] }).catch(() => {});
  console.error(`Browser account check failed at stage: ${stage}; private diagnostics excluded.`);
  process.exitCode = 1;
} finally { await browser?.close(); }
