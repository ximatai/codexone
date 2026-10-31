import { expect, test } from "./fixtures";
import { mkdir } from "node:fs/promises";

test("edits, clears and reconciles key display names on desktop and narrow layouts", async ({
  page,
}) => {
  const key = {
    id: "synthetic-key",
    principal: "legacy-synthetic",
    displayName: null as string | null,
    revision: 1,
    enabled: true,
    models: ["synthetic-text"],
    createdAtUnixSeconds: 1,
    limits: {
      requests: 500,
      active: 2,
      unresolved: 10,
      budgetMicros: null,
      unresolvedMicros: null,
    },
  };
  let conflict = false;
  let writes = 0;
  await page.route("**/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/session")
      return route.fulfill({
        json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      });
    if (path === "/api/keys")
      return route.fulfill({ json: { keys: [key], nextCursor: null } });
    if (path === "/api/keys/options")
      return route.fulfill({ json: { models: key.models, imageModels: [] } });
    if (path === "/api/usage/keys")
      return route.fulfill({
        json: {
          timezone: "UTC",
          startUnixSeconds: 0,
          endUnixSeconds: 86400,
          keys: [],
        },
      });
    if (path === "/api/keys/synthetic-key/display-name") {
      writes++;
      const body = route.request().postDataJSON();
      expect(body.revision).toBe(key.revision);
      if (conflict) {
        key.revision++;
        key.displayName = "另一个管理员";
        return route.fulfill({
          status: 409,
          json: { error: { code: "revision_conflict" } },
        });
      }
      key.revision++;
      key.displayName = body.displayName;
      return route.fulfill({ json: { key } });
    }
    return route.fulfill({
      status: 404,
      json: { error: { code: "synthetic_not_found" } },
    });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/keys");
  await page.getByRole("button", { name: "编辑", exact: true }).click();
  await page.getByLabel("显示名", { exact: true }).fill("合成显示名");
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByText("合成显示名", { exact: true })).toBeVisible();
  await expect(page.getByText("legacy-synthetic", { exact: true })).toHaveCSS(
    "color",
    "rgb(134, 142, 150)",
  );
  await page.getByPlaceholder(/搜索/).fill("合成显示名");
  await expect(
    page.getByRole("button", { name: "编辑", exact: true }),
  ).toBeVisible();
  await mkdir("../artifacts/key-display-name", { recursive: true });
  await expect(page.getByRole("dialog")).toBeHidden();
  await page.waitForTimeout(350);
  await page.screenshot({
    path: "../artifacts/key-display-name/keys-1440.png",
  });
  await page.getByRole("button", { name: "编辑", exact: true }).click();
  await page.getByLabel("显示名", { exact: true }).fill("过期修改");
  conflict = true;
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByText("数据已被修改，请确认后重试")).toBeVisible();
  expect(writes).toBe(2);
  await page.getByPlaceholder(/搜索/).fill("");
  await expect(page.getByText("另一个管理员", { exact: true })).toBeVisible();
  conflict = false;
  await page.getByRole("button", { name: "编辑", exact: true }).click();
  await page.getByLabel("显示名", { exact: true }).fill("");
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByText("另一个管理员", { exact: true })).toBeHidden();
  await expect(page.getByRole("dialog")).toBeHidden();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(350);
  await expect(
    page.getByText("legacy-synthetic", { exact: true }),
  ).toBeVisible();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({ path: "../artifacts/key-display-name/keys-390.png" });
});
