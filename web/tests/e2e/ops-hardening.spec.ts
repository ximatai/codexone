import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";
test("reviews unknown release, conflict and success at desktop size", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  let count = 512;
  let writes = 0;
  const account = {
    id: "12345678-synthetic",
    displayName: null,
    revision: 1,
    credentialVersion: 1,
    mode: "enabled",
    authorization: "ready",
    createdAtUnixSeconds: 1,
    accessExpiresAtUnixSeconds: Math.floor(Date.now() / 1000) + 3600,
    observability: observationFixture(),
  };
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/executions/unknown/release") {
      writes++;
      const body = route.request().postDataJSON();
      expect(body.expectedCount).toBe(count);
      expect(Number.isInteger(body.beforeUnixSeconds)).toBeTruthy();
      if (writes === 1) {
        count = 513;
        return route.fulfill({
          status: 409,
          json: { error: { code: "conflict" } },
        });
      }
      count = 0;
      return route.fulfill({ json: { released: 513 } });
    }
    const data: Record<string, unknown> = {
      "/api/session": { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      "/api/system": { service: "codexone", ready: true, checks: [] },
      "/api/attention": {
        generatedAtUnixSeconds: 1,
        items: count
          ? [
              {
                kind: "unresolved_executions",
                severity: "warning",
                subjectType: "system",
                subjectID: null,
                subjectName: null,
                detail: { count, unresolvedCount: count, limit: 1024 },
                sinceUnixSeconds: 1,
              },
            ]
          : [],
      },
      "/api/accounts": { accounts: [account], nextCursor: null },
      "/api/usage/keys": {
        timezone: "UTC",
        startUnixSeconds: 0,
        endUnixSeconds: 86400,
        keys: [],
      },
      "/api/runtime/storage": {
        pressure: "normal",
        admissionAllowed: true,
        optionalWorkAllowed: true,
      },
      "/api/usage/daily": { timezone: "UTC", days: 7, buckets: [] },
      "/api/usage/in-flight": { rows: [] },
      "/api/usage": { ...reportFixture(), rows: [], nextCursor: null },
    };
    if (path.endsWith("/observation"))
      return route.fulfill({ json: observationFixture() });
    return route.fulfill({ json: data[path] ?? {} });
  });
  await page.goto("/");
  await expect(page.getByText("未命名账号 · 12345678")).toBeVisible();
  await expect(page.getByText("访问凭证约 1 小时后到期")).toBeVisible();
  await page.getByLabel("自动刷新（15 秒）").uncheck();
  await page.getByRole("button", { name: "核对并释放" }).click();
  const dialog = page.getByRole("dialog", { name: "核对并释放待核对执行" });
  await expect(dialog).toContainText("真实用量无法得知");
  await expect(dialog).toContainText("统计中仍显示用量未知");
  await mkdir("../artifacts/ops-hardening", { recursive: true });
  await page.waitForTimeout(350);
  await page.screenshot({
    path: "../artifacts/ops-hardening/release-1440.png",
  });
  await dialog.getByRole("button", { name: "取消" }).click();
  expect(writes).toBe(0);
  await page.getByRole("button", { name: "核对并释放" }).click();
  await dialog.getByRole("button", { name: "确认释放" }).click();
  await expect(page.getByText(/待核对数量已变化/)).toBeVisible();
  await expect(page.getByText(/未结执行占用 513 \/ 1024/)).toBeVisible();
  await page.getByRole("button", { name: "核对并释放" }).click();
  await expect(dialog).toContainText("513 条");
  await dialog.getByRole("button", { name: "确认释放" }).click();
  await expect(page.getByText("暂无需要处理的事项")).toBeVisible();
  await expect(
    page.getByText("已释放容量占用，统计仍显示用量未知。"),
  ).toBeVisible();
  expect(writes).toBe(2);
  await page.getByRole("link", { name: "订阅账号", exact: true }).click();
  await expect(page.getByText("可在账号详情中设置名称")).toBeVisible();
  await expect(page.getByText("访问凭证约 1 小时后到期")).toBeVisible();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 1440);
});
