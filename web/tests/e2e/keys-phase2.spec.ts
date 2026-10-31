import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";

test("key status filters, menu actions, create drawer and narrow navigation", async ({
  page,
}) => {
  const keys = [
    {
      id: "synthetic-never",
      principal: "desktop-team",
      expiresAtUnixSeconds: null,
    },
    {
      id: "synthetic-soon",
      principal: "ci-team",
      expiresAtUnixSeconds: Math.floor(Date.now() / 1000) + 3 * 86400,
    },
    {
      id: "synthetic-expired",
      principal: "retired-team",
      expiresAtUnixSeconds: Math.floor(Date.now() / 1000) - 86400,
    },
  ].map((key) => ({
    ...key,
    revision: 1,
    enabled: true,
    models: ["synthetic-text"],
    createdAtUnixSeconds: 1700000000,
    limits: {
      requests: 500,
      active: 2,
      unresolved: 10,
      budgetMicros: null,
      unresolvedMicros: null,
    },
  }));
  await page.route("**/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/session")
      return route.fulfill({
        json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      });
    if (path === "/api/keys")
      return route.fulfill({ json: { keys, nextCursor: null } });
    if (path === "/api/keys/options")
      return route.fulfill({
        json: { models: ["synthetic-text"], imageModels: [] },
      });
    if (path === "/api/usage/keys")
      return route.fulfill({
        json: {
          timezone: "UTC",
          startUnixSeconds: Math.floor(Date.now() / 86400000) * 86400,
          endUnixSeconds: (Math.floor(Date.now() / 86400000) + 1) * 86400,
          keys: keys.map((key) => ({
            keyID: key.id,
            principal: key.principal,
            admitted: 0,
            failed: 0,
            pending: 0,
            estimatedMicros: "0",
            lastUsedAtUnixSeconds: null,
          })),
        },
      });
    return route.fulfill({
      status: 404,
      json: { error: { code: "synthetic_not_found" } },
    });
  });
  await mkdir("../artifacts/ui-phase2", { recursive: true });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/keys");
  await expect(page.getByText("desktop-team", { exact: true })).toBeVisible();
  await page
    .getByRole("radiogroup", { name: "密钥状态" })
    .getByText("即将到期", { exact: true })
    .click();
  await expect(page.getByText("ci-team", { exact: true })).toBeVisible();
  await expect(page.getByText("desktop-team", { exact: true })).toBeHidden();
  await expect(page.getByText("retired-team", { exact: true })).toBeHidden();
  await expect(page.getByText("共 1 个", { exact: true })).toBeVisible();
  await page
    .getByRole("radiogroup", { name: "密钥状态" })
    .getByText("全部", { exact: true })
    .click();
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/ui-phase2/keys-1440.png" });
  await page.getByRole("button", { name: "ci-team 更多操作" }).click();
  await expect(
    page.getByRole("menuitem", { name: "轮换", exact: true }),
  ).toBeVisible();
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/ui-phase2/keys-menu-1440.png" });
  await page.getByRole("menuitem", { name: "轮换", exact: true }).click();
  const rotation = page.getByRole("dialog", { name: "轮换 API Key" });
  await expect(rotation).toContainText("旧凭证将立即失效");
  await rotation.getByRole("button", { name: "取消", exact: true }).click();
  await page.getByRole("button", { name: "创建密钥", exact: true }).click();
  const create = page.getByRole("dialog", { name: "创建密钥", exact: true });
  await expect(create.getByLabel("主体标识")).toBeVisible();
  await page.waitForTimeout(350);
  await page.waitForTimeout(350);
  await page.screenshot({
    path: "../artifacts/ui-phase2/keys-create-1440.png",
  });
  await create.getByRole("button", { name: "取消", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await expect(
    page.getByRole("link", { name: "订阅账号", exact: true }),
  ).toBeHidden();
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/ui-phase2/keys-390.png" });
  await page.getByRole("button", { name: "打开导航" }).click();
  const nav = page.getByRole("dialog", { name: "CodexOne", exact: true });
  await expect(
    nav.getByRole("link", { name: "订阅账号", exact: true }),
  ).toBeVisible();
  await expect(page.locator("body")).toHaveCSS("overflow", "hidden");
  await nav.getByRole("link", { name: "订阅账号", exact: true }).click();
  await expect(nav).toBeHidden();
  await expect(page).toHaveURL(/#\/accounts/);
});
