import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("account drawer saves a display name and the card owns the stop and force-stop flow", async ({
  page,
}) => {
  const account = {
    id: "synthetic-account",
    revision: 1,
    credentialVersion: 1,
    displayName: "合成订阅",
    mode: "enabled",
    inFlight: 2,
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
    if (path === "/api/accounts/synthetic-account/force-stop") {
      const body = route.request().postDataJSON();
      expect(body.revision).toBe(account.revision);
      writes++;
      account.inFlight = 0;
      return route.fulfill({ json: { cancellationRequested: 1 } });
    }
    if (
      path === "/api/accounts/synthetic-account" &&
      route.request().method() === "PUT"
    ) {
      const body = route.request().postDataJSON();
      expect(body.revision).toBe(account.revision);
      account.mode = body.mode;
      account.revision++;
      return route.fulfill({ json: { account } });
    }
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
    drawer.getByRole("switch", { name: "已启用", exact: true }),
  ).toBeChecked();
  await drawer.getByLabel("账号显示名").fill("合成新名称");
  await drawer.getByRole("button", { name: "保存显示名" }).click();
  await expect(page.getByText("显示名已更新。", { exact: true })).toBeVisible();
  expect(writes).toBe(1);
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(drawer).not.toBeVisible();
  const toggle = page.getByRole("switch");
  await toggle.click();
  const remaining = page.getByText("正在等待 2 个请求结束");
  await expect(remaining).toBeVisible();
  await expect(toggle).not.toBeChecked();
  const force = page.getByRole("button", { name: "强行停用", exact: true });
  const waitBox = (await remaining.boundingBox())!;
  const forceBox = (await force.boundingBox())!;
  expect(waitBox.x).toBeLessThan(forceBox.x);
  expect(
    Math.abs(waitBox.y + waitBox.height / 2 - forceBox.y - forceBox.height / 2),
  ).toBeLessThan(4);
  await page.setViewportSize({ width: 390, height: 844 });
  await expectNoHorizontalOverflow(page);
  await force.click();
  const confirmation = page.getByRole("dialog", { name: "强行停用账号" });
  await expect(confirmation).toContainText("合成新名称");
  await confirmation.getByRole("button", { name: "继续等待" }).click();
  expect(writes).toBe(1);
  account.inFlight = 1;
  await expect(page.getByText("正在等待 1 个请求结束")).toBeVisible();
  await force.click();
  await confirmation.getByRole("button", { name: "确认强行停用" }).click();
  await expect(page.getByRole("switch", { name: "已停用" })).not.toBeChecked();
  await expect(force).toHaveCount(0);
  expect(writes).toBe(2);
});
