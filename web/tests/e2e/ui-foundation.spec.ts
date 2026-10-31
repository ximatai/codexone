import { expect, test } from "./fixtures";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";

for (const [width, height] of [
  [1440, 900],
  [390, 844],
]) {
  test(`Key foundation flows ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height });
    const violations: string[] = [];
    page.on("console", (message) => {
      if (/Content Security Policy|violates.*policy/i.test(message.text()))
        violations.push(message.text());
    });
    await page.route("**/api/session", (route) =>
      route.fulfill({
        json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      }),
    );
    const key = {
      id: "synthetic-key",
      principal: "synthetic-team",
      revision: 1,
      enabled: true,
      models: ["synthetic-text"],
      limits: {
        requests: 100,
        active: 2,
        unresolved: 10,
        budgetMicros: null,
        unresolvedMicros: null,
      },
      createdAtUnixSeconds: 1700000000,
      expiresAtUnixSeconds: null,
    };
    await page.route("**/api/keys", (route) =>
      route.fulfill({ json: { keys: [key], nextCursor: null } }),
    );
    await page.route("**/api/keys/options", (route) =>
      route.fulfill({ json: { models: key.models, imageModels: [] } }),
    );
    await page.route("**/api/usage/keys**", (route) =>
      route.fulfill({ json: { keys: [] } }),
    );
    await page.goto("/#/keys");
    await expect(
      page.getByText("synthetic-team", { exact: true }),
    ).toBeVisible();
    const phase = process.env.UI_FOUNDATION_SNAPSHOTS;
    const folder = resolve(
      process.env.UI_FOUNDATION_OUTPUT || "../artifacts/ui-foundation",
      phase || "after",
    );
    const capture = async (name: string) => {
      if (!phase) return;
      // Mantine starts transitions on a later animation frame; capture only the settled state.
      await page.waitForTimeout(350);
      await mkdir(folder, { recursive: true });
      await page.screenshot({
        path: `${folder}/${width}-${name}.png`,
        animations: "disabled",
      });
    };
    await capture("list");
    await page.getByRole("button", { name: "编辑", exact: true }).click();
    const editor = page.getByRole("dialog", { name: "编辑密钥权限" });
    await expect(editor).toBeVisible();
    if (process.env.UI_FOUNDATION_SNAPSHOTS !== "before") {
      await expect(page.locator("body")).toHaveCSS("overflow", "hidden");
      await expect(page.locator("style:not([data-vite-dev-id])")).toHaveCount(
        0,
      );
    }
    await capture("edit");
    await editor.getByRole("button", { name: "取消", exact: true }).click();
    await page.getByRole("button", { name: "synthetic-team 更多操作" }).click();
    await page.getByRole("menuitem", { name: "设置到期时间" }).click();
    await expect(
      page.getByRole("dialog", { name: "设置 Key 到期时间" }),
    ).toBeVisible();
    await capture("expiration");
    await page.keyboard.press("Escape");
    await page.getByRole("button", { name: "synthetic-team 更多操作" }).click();
    await page.getByRole("menuitem", { name: "禁用", exact: true }).click();
    await expect(
      page.getByRole("dialog", { name: "禁用 API Key" }),
    ).toBeVisible();
    await capture("disable");
    await page.getByRole("button", { name: "取消", exact: true }).click();
    await expect(page.locator("body")).toHaveJSProperty("scrollWidth", width);
    expect(violations).toEqual([]);
  });
}
