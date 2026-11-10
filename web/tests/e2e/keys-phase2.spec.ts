import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { mkdir } from "node:fs/promises";
import { reviewFixture } from "./ui-review-fixture";

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
      tokens: 500,
      active: 2,
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
  await page.getByRole("combobox", { name: "可用状态", exact: true }).click();
  await page.getByRole("option", { name: "即将到期", exact: true }).click();
  await expect(page.getByText("ci-team", { exact: true })).toBeVisible();
  await expect(page.getByText("desktop-team", { exact: true })).toBeHidden();
  await expect(page.getByText("retired-team", { exact: true })).toBeHidden();
  await expect(page.getByText("共 1 个", { exact: true })).toBeVisible();
  await page.getByRole("combobox", { name: "可用状态", exact: true }).click();
  await page.getByRole("option", { name: "全部", exact: true }).click();
  await expect(
    page.getByRole("row").filter({ hasText: "ci-team" }),
  ).toContainText("7 天内到期");
  await expect(
    page.getByRole("row").filter({ hasText: "retired-team" }),
  ).toContainText("已到期");
  await expect(
    page.getByRole("row").filter({ hasText: "desktop-team" }),
  ).toContainText("可用");
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/ui-phase2/keys-1440.png" });
  await page
    .getByRole("row")
    .filter({ hasText: "ci-team" })
    .getByRole("button", { name: "查看详情" })
    .click();
  await expect(
    page.getByRole("button", { name: "轮换凭证", exact: true }),
  ).toBeVisible();
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/ui-phase2/keys-menu-1440.png" });
  await page.getByRole("button", { name: "轮换凭证", exact: true }).click();
  const rotation = page.getByRole("dialog", { name: "轮换 API Key" });
  await expect(rotation).toContainText("旧凭证将立即失效");
  await rotation.getByRole("button", { name: "取消", exact: true }).click();
  await page
    .getByRole("dialog", { name: "密钥详情" })
    .getByRole("button", { name: "关闭", exact: true })
    .click();
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
  await expectNoHorizontalOverflow(page);
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

test("desktop sidebar collapses across pages and reloads without hiding mobile drawer labels", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/keys");
  const sidebar = page.locator("#workspace-sidebar");
  const keys = sidebar.getByRole("link", { name: "访问密钥", exact: true });
  const collapse = sidebar.getByRole("button", { name: "收起侧栏" });
  const expand = sidebar.getByRole("button", { name: "展开侧栏" });
  await expect(collapse).toHaveAttribute("aria-expanded", "true");
  await expect(sidebar).toHaveCSS("width", "224px");
  await expect(sidebar).toHaveCSS("transition-duration", "0.18s, 0.18s");
  const bottomGap = (button: typeof collapse) =>
    button.evaluate((element) =>
      Math.round(window.innerHeight - element.getBoundingClientRect().bottom),
    );
  expect(await bottomGap(collapse)).toBe(16);
  await collapse.focus();
  await collapse.press("Enter");
  await expect(expand).toHaveAttribute("aria-expanded", "false");
  await expect(sidebar).toHaveCSS("width", "64px");
  expect(await bottomGap(expand)).toBe(16);
  await expect(keys).toBeVisible();
  await expect(keys.getByText("访问密钥", { exact: true })).toBeHidden();
  await expect(keys).toHaveAttribute("aria-current", "page");
  await sidebar.getByRole("link", { name: "订阅账号", exact: true }).click();
  await expect(page).toHaveURL(/#\/accounts/);
  await expect(expand).toBeVisible();
  await page.reload();
  await expect(sidebar).toHaveCSS("width", "64px");
  await expectNoHorizontalOverflow(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(expand).toBeHidden();
  await page.getByRole("button", { name: "打开导航" }).click();
  const drawer = page.getByRole("dialog", { name: "CodexOne" });
  await expect(drawer.getByText("访问密钥", { exact: true })).toBeVisible();
  await drawer.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(drawer).toBeHidden();
  await expectNoHorizontalOverflow(page);

  await page.setViewportSize({ width: 1440, height: 900 });
  await expand.click();
  await expect(sidebar).toHaveCSS("width", "224px");
  await expect(keys.getByText("访问密钥", { exact: true })).toBeVisible();
  await expect(collapse).toHaveAttribute("aria-expanded", "true");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(sidebar).toHaveCSS("transition-duration", "0s");
});
