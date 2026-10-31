import { expect, test } from "./fixtures";
import { reportFixture } from "../../src/features/usage/usage.test-data";

test("browser login form and request effort evidence", async ({ page }) => {
  let authenticated = false;
  const logins: { username: string; secret: string }[] = [];
  let selectedEffort = "";
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/session") {
      if (route.request().method() === "POST") {
        const body = route.request().postDataJSON();
        logins.push(body);
        authenticated =
          body.username === "admin" && body.secret === "synthetic-valid-secret";
      }
      return route.fulfill({
        status: authenticated ? 200 : 401,
        json: authenticated
          ? { authenticated: true, csrf: "ac1_" + "a".repeat(43) }
          : { error: { code: "invalid_admin_credential" } },
      });
    }
    if (url.pathname === "/api/usage/options")
      return route.fulfill({
        json: {
          keys: ["alpha"],
          models: ["synthetic-text"],
          failures: [],
          defaultReasoningEfforts: { "synthetic-text": "high" },
        },
      });
    if (url.pathname === "/api/usage") {
      selectedEffort = url.searchParams.get("reasoningEffort") ?? "";
      const report = reportFixture();
      return route.fulfill({
        json: {
          ...report,
          rows: [
            {
              ...report.rows[0],
              id: "explicit",
              reasoningEffort: "xhigh",
              serviceTier: "priority",
              actualServiceTier: "default",
              requestMetadataRecorded: true,
            },
            {
              ...report.rows[0],
              id: "default",
              reasoningEffort: null,
              serviceTier: null,
              actualServiceTier: null,
              requestMetadataRecorded: true,
            },
            { ...report.rows[0], id: "historical" },
            {
              ...report.rows[0],
              id: "unconfigured-default",
              model: "synthetic-other",
              reasoningEffort: null,
              requestMetadataRecorded: true,
            },
          ],
        },
      });
    }
    return route.fulfill({ status: 404, json: {} });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/#/usage");
  const username = page.getByLabel("用户名", { exact: true });
  const password = page.getByLabel("管理员凭证", { exact: true });
  await expect(username).toHaveValue("admin");
  await expect(username).toHaveAttribute("name", "username");
  await expect(username).toHaveAttribute("autocomplete", "username");
  await expect(password).toHaveAttribute("name", "password");
  await expect(password).toHaveAttribute("autocomplete", "current-password");
  await expect(password).toHaveAttribute("type", "password");
  await expect(
    page
      .locator("form")
      .filter({ has: username })
      .locator('button[type="submit"]'),
  ).toHaveText("登录管理台");
  await username.fill("Admin");
  await password.fill("synthetic-valid-secret");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "管理员凭证无效，请重新输入。",
  );
  await username.fill("admin");
  await password.fill("synthetic-wrong-secret");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "管理员凭证无效，请重新输入。",
  );
  await password.fill("synthetic-valid-secret");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(
    page.getByRole("columnheader", { name: "推理", exact: true }),
  ).toBeVisible();
  const rows = page.locator(".usage-table tbody tr");
  await expect(rows.nth(0)).toContainText("xhigh");
  await expect(rows.nth(1)).toContainText("默认 · high");
  await expect(rows.nth(2).locator("td").nth(2)).toContainText("—");
  await expect(rows.nth(3).locator("td").nth(2)).toHaveText("推理默认");
  await rows.nth(0).click();
  const drawer = page.getByRole("dialog", { name: "请求详情" });
  await expect(drawer).toContainText("请求服务档位");
  await expect(drawer).toContainText("priority");
  await expect(drawer).toContainText("实际服务档位");
  await expect(drawer).toContainText("default");
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await page.getByLabel("推理强度", { exact: true }).fill("xhigh");
  await page.getByRole("button", { name: "查询用量", exact: true }).click();
  await expect.poll(() => selectedEffort).toBe("xhigh");
  expect(logins).toHaveLength(3);
  expect(
    await page.evaluate(() => [localStorage.length, sessionStorage.length]),
  ).toEqual([0, 0]);
  await page.screenshot({
    path: "../artifacts/session-effort-1440.png",
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.screenshot({
    path: "../artifacts/session-effort-390.png",
    fullPage: true,
  });
});
