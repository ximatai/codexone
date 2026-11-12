import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("account drawer saves a display name and can cancel disabling the account", async ({
  page,
}) => {
  const account = {
    id: "synthetic-account",
    revision: 1,
    credentialVersion: 1,
    displayName: "合成订阅",
    mode: "enabled",
    authorization: "ready",
    createdAtUnixSeconds: 1,
    accessExpiresAtUnixSeconds: null,
    credentialUpdatedAtUnixSeconds: null,
    observability: observationFixture(),
  };
  let writes = 0;
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/session")
      return route.fulfill({
        json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      });
    if (path === "/api/accounts")
      return route.fulfill({ json: { accounts: [account], nextCursor: null } });
    if (path.endsWith("/observation"))
      return route.fulfill({ json: observationFixture() });
    if (path.endsWith("/display-name")) {
      writes++;
      account.displayName = route.request().postDataJSON().displayName;
      account.revision++;
      return route.fulfill({ json: { account } });
    }
    return route.fulfill({ status: 404, json: {} });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/accounts");
  await expect(page.getByText("合成订阅", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "额度与健康详情" })).toHaveText(
    "查看详情",
  );
  await expect(page.getByRole("button", { name: /更多操作/ })).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "额度与健康详情" }),
  ).toHaveCount(1);
  await page.getByRole("button", { name: "额度与健康详情" }).click();
  const drawer = page.getByRole("dialog", { name: "账号详情" });
  await drawer.getByRole("tab", { name: "设置", exact: true }).click();
  await drawer.getByText("技术信息", { exact: true }).click();
  await expect(drawer).toContainText("访问凭证到期：不可用");
  await expect(
    drawer.getByRole("radio", { name: "启用", exact: true }),
  ).toBeChecked();
  await drawer.getByLabel("账号显示名").fill("合成新名称");
  await drawer.getByRole("button", { name: "保存显示名" }).click();
  await expect(page.getByText("显示名已更新。", { exact: true })).toBeVisible();
  expect(writes).toBe(1);
  await drawer.getByRole("radio", { name: "禁用", exact: true }).click();
  const confirmation = page.getByRole("dialog", {
    name: "禁用账号",
    exact: true,
  });
  await expect(confirmation).toBeVisible();
  await expect(drawer).toBeVisible();
  await expect(drawer.getByLabel("账号显示名")).toHaveValue("合成新名称");
  await confirmation.getByRole("button", { name: "取消", exact: true }).click();
  await expect(drawer).toBeVisible();
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(drawer).not.toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expectNoHorizontalOverflow(page);
});
