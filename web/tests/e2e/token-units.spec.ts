import { test, expect } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";
for (const width of [1920, 390])
  test(`Token units preserve quantity and save only Token/concurrency at ${width}`, async ({
    page,
  }) => {
    let key = {
      id: "synthetic-token",
      principal: "synthetic-tool",
      revision: 1,
      enabled: true,
      models: ["synthetic-text"],
      limits: { tokens: 1500000, active: 4 },
      createdAtUnixSeconds: 1,
    };
    let saved: unknown;
    await page.route("**/api/**", async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (path === "/api/session")
        return route.fulfill({
          json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
        });
      if (path === "/api/keys")
        return route.fulfill({ json: { keys: [key], nextCursor: null } });
      if (path === "/api/keys/options")
        return route.fulfill({
          json: { models: ["synthetic-text"], imageModels: [] },
        });
      if (path === "/api/keys/synthetic-token") {
        saved = route.request().postDataJSON();
        key = { ...key, ...(saved as object), revision: 2 };
        return route.fulfill({ json: { key } });
      }
      return route.fulfill({ status: 404, json: {} });
    });
    await page.setViewportSize({ width, height: width === 1920 ? 1680 : 844 });
    await page.goto("/#/keys");
    await page.getByRole("button", { name: "查看详情" }).click();
    await page.getByText("本地治理限额", { exact: true }).click();
    const amount = page.getByLabel("每日 Token 上限", { exact: true }),
      unit = page.getByRole("combobox", { name: "Token 单位", exact: true });
    await expect(amount).toHaveValue("1.5");
    await unit.click();
    await expect(
      page.getByRole("option", { name: "Token", exact: true }),
    ).toBeVisible();
    await unit.press("Escape");
    await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeVisible();
    await expect(page.getByRole("listbox")).toBeHidden();
    await unit.click();
    await page.getByRole("option", { name: "万 Token", exact: true }).click();
    await expect(amount).toHaveValue("150");
    await unit.click();
    await page.getByRole("option", { name: "Token", exact: true }).click();
    await expect(amount).toHaveValue("1500000");
    await unit.click();
    await page.getByRole("option", { name: "百万 Token", exact: true }).click();
    await amount.fill("");
    await amount.pressSequentially("2.5");
    await expect(amount).toHaveValue("2.5");
    await expect(
      page.getByRole("button", { name: "保存修改" }),
    ).toBeInViewport();
    await expect(
      page
        .getByRole("dialog", { name: "密钥详情" })
        .getByRole("button", { name: "关闭", exact: true }),
    ).toBeInViewport();
    await page.getByRole("button", { name: "保存修改" }).click();
    await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
    expect(saved).toMatchObject({ limits: { tokens: 2500000, active: 4 } });
    expect(Object.keys((saved as { limits: object }).limits).sort()).toEqual([
      "active",
      "tokens",
    ]);
    await expectNoHorizontalOverflow(page);
  });
