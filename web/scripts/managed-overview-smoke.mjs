import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { chromium } from "playwright";

const [origin, credentialPath] = process.argv.slice(2);
const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  const page = await browser.newPage();
  page.setDefaultTimeout(8000);
  const faults = [];
  page.on("pageerror", (error) => faults.push(String(error)));
  const snapshot = new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("overview snapshot timed out")),
      8000,
    );
    page.on("websocket", (socket) => {
      if (!socket.url().endsWith("/api/overview/live")) return;
      socket.on("framereceived", ({ payload }) => {
        if (typeof payload !== "string") return;
        const frame = JSON.parse(payload);
        if (frame.kind === "snapshot") {
          clearTimeout(timer);
          resolve(frame);
        }
      });
    });
  });
  await page.goto(origin);
  await page.getByRole("button", { name: "管理员登录" }).click();
  await page.getByLabel("用户名", { exact: true }).fill("admin");
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill(readFileSync(credentialPath, "utf8"));
  await page.getByRole("button", { name: "登录管理台" }).click();
  const frame = await snapshot;
  const accounts = frame.sections.accounts.data.accounts;
  assert(accounts.some((account) => account.id === "account-a"));
  assert(
    accounts.some(
      (account) =>
        account.id === "account-c" &&
        account.authorization === "auth_uncertain",
    ),
  );
  const attention = frame.sections.attention.data.items;
  assert(
    attention.some(
      (item) =>
        item.kind === "account_auth_uncertain" &&
        item.subjectID === "account-c",
    ),
  );
  assert(
    attention.some(
      (item) =>
        item.kind === "quota_stale" && item.detail.reason === "unavailable",
    ),
  );
  await page.getByRole("region", { name: "今日 Key 请求汇总" }).waitFor();
  await page.locator('a[href="#/?account=account-a"]').waitFor();
  await page.getByText("额度不可用", { exact: true }).first().waitFor();

  // Keep a second connection under the same browser session to verify that
  // logout revokes server-side connections in addition to unmounting the SPA.
  await page.evaluate(() => {
    globalThis.revokeWitness = new WebSocket(
      `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/api/overview/live`,
    );
    globalThis.revoked = new Promise((resolve) => {
      globalThis.revokeWitness.addEventListener(
        "close",
        (event) => resolve(event.code),
        { once: true },
      );
    });
    return new Promise((resolve, reject) => {
      globalThis.revokeWitness.addEventListener("open", resolve, {
        once: true,
      });
      globalThis.revokeWitness.addEventListener("error", reject, {
        once: true,
      });
    });
  });
  const report = page.waitForResponse(
    (response) =>
      response.status() === 200 &&
      new URL(response.url()).pathname === "/api/usage",
  );
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  await page.getByRole("heading", { name: "用量与诊断" }).waitFor();
  assert(
    (await (await report).json()).rows.some(
      (row) => row.model === "synth-text" && row.outcome === "succeeded",
    ),
  );
  await page.getByText("synth-text", { exact: true }).first().waitFor();
  await page.getByRole("button", { name: "退出登录" }).click();
  await page.getByRole("heading", { name: "管理员登录" }).waitFor();
  assert.equal(
    await page.evaluate(() =>
      Promise.race([
        globalThis.revoked,
        new Promise((resolve) => setTimeout(() => resolve(null), 6000)),
      ]),
    ),
    1008,
  );
  assert.deepEqual(faults, []);
  console.log(
    "PASS: managed SPA accounts, attention, settled usage, logout and same-session revocation",
  );
} finally {
  await browser.close();
}
