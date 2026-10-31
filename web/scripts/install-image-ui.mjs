// Browser exercises the packaged SPA and actual container API through a curl relay.
// HTTPS route fulfillment supplies browser cookie semantics; it does not test TLS/Nginx.
import { openChrome } from "./browser.mjs";
import { expect } from "@playwright/test";
import { spawnSync } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import assert from "node:assert/strict";

let input = "";
for await (const chunk of process.stdin) { input += chunk; assert(input.length < 4096); }
const { container, credential, output } = JSON.parse(input);
assert(/^[0-9a-f]{12,64}$/.test(container));
const origin = "https://admin.example.invalid";
const secrets = [credential];
let browser, page, stage = "launch";
try {
  browser = await openChrome();
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  await context.route("**/*", async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.origin !== origin) return route.abort();
    try {
      const headers = await request.allHeaders();
      const settings = ["url = " + JSON.stringify("http://127.0.0.1:18081" + url.pathname + url.search),
        "request = " + JSON.stringify(request.method()), 'header = "Host: admin.example.invalid"'];
      for (const name of ["cookie", "origin", "sec-fetch-site", "content-type", "x-codexone-csrf"]) {
        if (headers[name]) settings.push("header = " + JSON.stringify(name + ": " + headers[name]));
      }
      const body = request.postDataBuffer();
      if (body) settings.push("data = " + JSON.stringify(body.toString("utf8")));
      const result = spawnSync("docker", ["exec", "-i", container, "curl", "--silent", "--show-error", "--max-time", "5",
        "--dump-header", "-", "--write-out", "\n%{http_code}", "--config", "-"],
        { input: settings.join("\n") + "\n", timeout: 10000, maxBuffer: 524288 });
      assert(result.status === 0 && result.stdout.length < 524288);
      const split = result.stdout.indexOf("\r\n\r\n"), end = result.stdout.lastIndexOf("\n");
      assert(split > 0 && end > split);
      const responseHeaders = {};
      for (const line of result.stdout.subarray(0, split).toString().split("\r\n").slice(1)) {
        const colon = line.indexOf(":"), name = line.slice(0, colon).toLowerCase();
        if (colon > 0 && !["connection", "keep-alive", "transfer-encoding", "content-length"].includes(name)) {
          responseHeaders[name] = line.slice(colon + 1).trim();
        }
      }
      await route.fulfill({ status: Number(result.stdout.subarray(end + 1)), headers: responseHeaders,
        body: result.stdout.subarray(split + 4, end) });
    } catch { errors.push("container relay failed"); await route.abort(); }
  });
  page = await context.newPage();
  page.on("pageerror", () => errors.push("page error"));
  page.on("console", entry => { if (/content security policy|refused to execute|refused to apply/i.test(entry.text())) errors.push("CSP error"); });
  stage = "login";
  await page.goto(origin);
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录" })).toBeVisible();
  await page.getByLabel("管理员凭证", { exact: true }).fill(credential);
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(page.getByRole("button", { name: "创建密钥", exact: true })).toBeEnabled();
  const cookie = (await context.cookies(origin)).find(item => item.name === "__Host-codexone_admin");
  assert(cookie?.secure && cookie.httpOnly && cookie.sameSite === "Strict");
  secrets.push(cookie.value);
  stage = "create and reload";
  await page.getByRole("button", { name: "创建密钥", exact: true }).click();
  await page.getByLabel("主体标识", { exact: true }).fill("browser-install");
  await page.getByRole("checkbox", { name: "configure-model-before-use", exact: true }).check();
  await page.getByRole("button", { name: "创建 API Key", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "保存一次性凭证" });
  await expect(dialog).toBeVisible();
  const keySecret = await dialog.getByLabel("新 API Key", { exact: true }).inputValue();
  assert(/^co1_[A-Za-z0-9_-]{43}$/.test(keySecret));
  secrets.push(keySecret);
  await dialog.getByRole("button", { name: "我已保存，关闭" }).click();
  await page.reload();
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(page.getByRole("row").filter({ hasText: "browser-install" })).toBeVisible();
  assert(await page.evaluate(() => !localStorage.length && !sessionStorage.length));
  const html = await page.content();
  assert(secrets.every(secret => !html.includes(secret)));
  assert(errors.length === 0);
  await mkdir(output, { recursive: true });
  await page.screenshot({ path: resolve(output, "desktop.png"), fullPage: true,
    mask: [page.locator('input[type="password"]'), page.locator("input.secret-value")] });
  stage = "logout";
  await page.getByRole("button", { name: "退出登录", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录" })).toBeVisible();
  assert(!(await context.cookies(origin)).some(item => item.name === "__Host-codexone_admin"));
  const logs = spawnSync("docker", ["logs", container], { timeout: 10000, maxBuffer: 65536 });
  assert(logs.status === 0 && secrets.every(secret => !Buffer.concat([logs.stdout, logs.stderr]).includes(Buffer.from(secret))));
  console.log("PASS: actual packaged SPA in Chrome: login, secure session, create/clear/reload and logout; container API relay, no TLS/proxy claim");
} catch {
  console.error("FAIL: packaged SPA browser check at " + stage);
  process.exitCode = 1;
} finally { await browser?.close(); }
