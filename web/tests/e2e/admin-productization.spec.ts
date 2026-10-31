import { expect, test } from "./fixtures";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("login overview, Key search, confirmed disabling, automatic usage and request details", async ({
  page,
  context,
}, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  let authenticated = false,
    mutations = 0,
    reads = 0;
  const limits = {
    requests: 100,
    active: 4,
    unresolved: 8,
    budgetMicros: 1000000,
    unresolvedMicros: 1000000,
  };
  const keys = [
    {
      id: "alpha",
      principal: "synthetic-team",
      revision: 1,
      enabled: true,
      models: ["synthetic-text"],
      limits,
      createdAtUnixSeconds: 1,
    },
    {
      id: "beta",
      principal: "other-team",
      revision: 1,
      enabled: false,
      models: ["synthetic-text"],
      limits,
      createdAtUnixSeconds: 1,
    },
  ];
  await page.route("**/api/session", (route) => {
    if (route.request().method() === "POST") authenticated = true;
    return route.fulfill({
      status: authenticated ? 200 : 401,
      json: authenticated
        ? { authenticated: true, csrf: "ac1_" + "a".repeat(43) }
        : { error: { code: "unauthorized" } },
    });
  });
  await page.route("**/api/attention", (route) =>
    route.fulfill({ json: { items: [], generatedAtUnixSeconds: 1 } }),
  );
  await page.route("**/api/system", (route) =>
    route.fulfill({ json: { service: "codexone", ready: true, checks: [] } }),
  );
  await page.route("**/api/accounts", (route) =>
    route.fulfill({
      json: {
        accounts: [
          {
            id: "synthetic-account",
            revision: 1,
            credentialVersion: 1,
            mode: "enabled",
            authorization: "ready",
            createdAtUnixSeconds: 1,
            observability: observationFixture(),
          },
        ],
        nextCursor: null,
      },
    }),
  );
  await page.route("**/api/runtime/storage", (route) =>
    route.fulfill({
      json: {
        pressure: "normal",
        admissionAllowed: true,
        optionalWorkAllowed: true,
      },
    }),
  );
  await page.route("**/api/keys/options", (route) =>
    route.fulfill({ json: { models: ["synthetic-text"], imageModels: [] } }),
  );
  await page.route("**/api/keys", (route) =>
    route.fulfill({ json: { keys, nextCursor: null } }),
  );
  await page.route("**/api/keys/alpha", (route) => {
    mutations++;
    Object.assign(keys[0], route.request().postDataJSON(), { revision: 2 });
    return route.fulfill({ json: { key: keys[0] } });
  });
  await page.route("**/api/usage/keys", (route) => {
    const start = Math.floor(Date.now() / 86400000) * 86400;
    return route.fulfill({
      json: {
        timezone: "UTC",
        startUnixSeconds: start,
        endUnixSeconds: start + 86400,
        keys: keys.map((key) => ({
          keyID: key.id,
          principal: key.principal,
          admitted: 2,
          failed: 1,
          pending: 1,
          estimatedMicros: "1250000",
          lastUsedAtUnixSeconds: start,
        })),
      },
    });
  });
  await page.route("**/api/usage/options", (route) =>
    route.fulfill({
      json: {
        keys: keys.map((k) => k.id),
        keyOptions: keys.map((k) => ({ id: k.id, principal: k.principal })),
        models: ["synthetic-text"],
        failures: [],
      },
    }),
  );
  await page.route(/\/api\/usage\?/, (route) => {
    reads++;
    const report = reportFixture();
    const rows = report.rows.map((row) => ({
      ...row,
      principal: "synthetic-team",
      firstEventMilliseconds: 12,
      totalMilliseconds: 34,
    }));
    return route.fulfill({ json: { ...report, rows } });
  });
  await page.goto("/#/keys");
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-admin-only");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(page.getByRole("heading", { name: "访问密钥" })).toBeVisible();
  await page.getByRole("link", { name: "服务概览", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "今日运营概览" }),
  ).toBeVisible();
  await expect(page.getByText(/允许准入/)).toBeVisible();
  await expect(page.getByText("今日请求 / 失败", { exact: true })).toHaveCount(
    0,
  );
  await expect(page.getByText(/^费用：/)).toHaveCount(0);
  await page.screenshot({
    path: testInfo.outputPath("admin-overview-1440.png"),
    fullPage: true,
  });
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await page.getByLabel("搜索主体名").fill("synthetic");
  await expect(page.getByText("other-team", { exact: true })).toBeHidden();
  await page.getByLabel("可用状态", { exact: true }).selectOption("disabled");
  await expect(page.getByText("没有匹配的密钥。")).toBeVisible();
  await page.getByLabel("可用状态", { exact: true }).selectOption("available");
  await page.getByRole("button", { name: "synthetic-team 更多操作" }).click();
  await page.getByRole("menuitem", { name: "禁用", exact: true }).click();
  const confirm = page.getByRole("dialog", { name: "禁用 API Key" });
  await expect(confirm).toContainText("客户端会立即失败");
  await confirm.getByRole("button", { name: "取消", exact: true }).click();
  expect(mutations).toBe(0);
  await expect(
    page.getByRole("row").filter({ hasText: "synthetic-team" }),
  ).toContainText("启用");
  await page.getByRole("button", { name: "synthetic-team 更多操作" }).click();
  await page.getByRole("menuitem", { name: "禁用", exact: true }).click();
  await confirm.getByRole("button", { name: "确认禁用" }).click();
  await expect(confirm).toBeHidden();
  expect(mutations).toBe(1);
  await page.getByLabel("可用状态", { exact: true }).selectOption("disabled");
  const row = page.getByRole("row").filter({ hasText: "synthetic-team" });
  await expect(row).toContainText("禁用");
  await page.screenshot({
    path: testInfo.outputPath("admin-keys-1440.png"),
    fullPage: true,
  });
  await row.getByRole("link", { name: "用量", exact: true }).click();
  await expect(page.getByLabel("Key 主体")).toHaveValue("alpha");
  await expect(page.locator(".usage-table")).toContainText("synthetic-team");
  expect(reads).toBeGreaterThan(0);
  await page.getByRole("button", { name: "查看详情" }).first().click();
  const detail = page.getByRole("dialog", { name: "请求详情" });
  await expect(detail).toContainText("12 ms");
  await expect(detail).toContainText("34 ms");
  await detail.getByRole("button", { name: "复制请求 ID" }).click();
  await expect(detail.getByRole("status")).toHaveText("已复制请求 ID");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
    reportFixture().rows[0].requestID,
  );
  await page.screenshot({
    path: testInfo.outputPath("admin-request-detail-1440.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await detail.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({
    path: testInfo.outputPath("admin-usage-390.png"),
    fullPage: true,
  });
});
