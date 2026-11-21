import { expect, test } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";

test("LAN HTTP keeps the risk warning visible throughout a cookie-backed browser session", async ({
  page,
  context,
  baseURL,
}) => {
  const name = "codexone_admin";
  const cookie = name + "=as1_" + "a".repeat(43);
  const csrf = "ac1_" + "b".repeat(43);
  const cookieAttributes = "Path=/; HttpOnly; SameSite=Strict";

  await page.route("**/api/system", (route) =>
    route.fulfill({
      json: {
        service: "codexone",
        ready: false,
        checks: [],
        transportMode: "lan_http",
      },
    }),
  );
  // Match the LAN Set-Cookie contract in rust/admin/tests/contract.rs.
  // Reads rely on the browser sending its cookie, including after a reload.
  await page.route("**/api/session", async (route) => {
    const request = route.request();
    const method = request.method();
    if (method === "POST")
      return route.fulfill({
        headers: {
          "Set-Cookie": `${cookie}; Max-Age=3600; ${cookieAttributes}`,
        },
        json: { authenticated: true, csrf },
      });
    if ((await request.headerValue("cookie")) !== cookie)
      return route.fulfill({
        status: 401,
        json: { error: { code: "invalid_admin_credential" } },
      });
    if (method === "DELETE") {
      expect(await request.headerValue("x-codexone-csrf")).toBe(csrf);
      return route.fulfill({
        headers: { "Set-Cookie": `${name}=; Max-Age=0; ${cookieAttributes}` },
        json: { authenticated: false },
      });
    }
    return route.fulfill({ json: { authenticated: true, csrf } });
  });
  await page.route("**/api/keys", (route) =>
    route.fulfill({ json: { keys: [], nextCursor: null } }),
  );
  await page.route("**/api/keys/options", (route) =>
    route.fulfill({ json: { models: ["synthetic-text"], imageModels: [] } }),
  );
  await page.route("**/api/accounts", (route) =>
    route.fulfill({ json: { accounts: [], nextCursor: null } }),
  );

  const banner = page.getByRole("alert", { name: "局域网明文风险" });
  const login = page.getByRole("button", { name: "登录管理台", exact: true });
  const logout = page.getByRole("button", { name: "退出登录", exact: true });
  const sessionCookies = async () =>
    (await context.cookies(baseURL)).filter((item) => item.name === name);

  await page.goto("/#/keys");
  await expect(banner).toBeVisible();
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-lan-secret");
  await login.click();
  await expect(logout).toBeEnabled();
  await expect(banner).toBeVisible();
  expect(await sessionCookies()).toMatchObject([
    { secure: false, httpOnly: true, sameSite: "Strict", path: "/" },
  ]);

  await page.reload();
  await expect(logout).toBeEnabled();
  await expect(banner).toBeVisible();
  await page.getByRole("link", { name: "订阅账号", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "订阅账号", exact: true }),
  ).toBeVisible();
  await expect(banner).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expectNoHorizontalOverflow(page);

  await logout.click();
  await expect(login).toBeEnabled();
  await expect(banner).toBeVisible();
  expect(await sessionCookies()).toEqual([]);
  expect(
    await page.evaluate(() => [localStorage.length, sessionStorage.length]),
  ).toEqual([0, 0]);
});
