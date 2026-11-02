import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { reportFixture } from "../../src/features/usage/usage.test-data";

test("desktop unlimited Key editing, payload and usage policy display", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  const limits = { tokens: null, active: null };
  let key = {
    id: "synthetic-key",
    principal: "synthetic-team",
    revision: 1,
    enabled: true,
    models: ["synthetic-text"],
    limits,
    createdAtUnixSeconds: 1,
  };
  let updated: unknown;
  await page.route("**/api/session", (route) =>
    route.fulfill({
      json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
    }),
  );
  await page.route("**/api/keys/options", (route) =>
    route.fulfill({ json: { models: ["synthetic-text"], imageModels: [] } }),
  );
  await page.route("**/api/keys", (route) =>
    route.fulfill({ json: { keys: [key], nextCursor: null } }),
  );
  await page.route("**/api/keys/synthetic-key", async (route) => {
    updated = route.request().postDataJSON();
    key = { ...key, ...(updated as object), revision: 2 };
    await route.fulfill({ json: { key } });
  });
  await page.route("**/api/usage/options", (route) =>
    route.fulfill({
      json: { keys: [key.id], models: key.models, failures: [] },
    }),
  );
  await page.route("**/api/usage?**", (route) =>
    route.fulfill({ json: reportFixture() }),
  );
  await page.goto("/#/keys");
  await expect(page.getByText(/\/ 不限 Token/)).toBeVisible();
  await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
  await page.getByRole("button", { name: "查看详情" }).click();
  await page.getByText("本地治理限额", { exact: true }).click();
  const toggle = page.getByRole("checkbox", { name: "每日 Token 上限不限" });
  const input = page.getByLabel("每日 Token 上限", { exact: true });
  await expect(toggle).toBeChecked();
  await expect(input).toBeDisabled();
  await toggle.uncheck();
  await input.fill("17");
  await toggle.check();
  await expect(input).toBeDisabled();
  await page.screenshot({
    path: testInfo.outputPath("unlimited-editor-desktop.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByRole("button", { name: "保存修改" })).toBeHidden();
  expect(updated).toMatchObject({ limits });
  await page.getByRole("button", { name: "查看详情" }).click();
  await page.getByRole("link", { name: "查看用量与诊断", exact: true }).click();
  await page
    .getByRole("button", { name: "更多统计与用量证据", exact: true })
    .click();
  await expect(page.getByText(/当前 Key 限额：/)).toContainText(
    "每日 Token 上限 不限",
  );
  await page.screenshot({
    path: testInfo.outputPath("unlimited-usage-desktop.png"),
    fullPage: true,
  });
  await expectNoHorizontalOverflow(page);
});
