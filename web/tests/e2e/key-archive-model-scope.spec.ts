import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import type { ManagedKey } from "../../src/features/key-management/api";

test("desktop archive, recycle bin, restore and independent all-model scopes", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  let key: ManagedKey = {
    id: "synthetic-archive",
    principal: "synthetic-team",
    revision: 1,
    enabled: true,
    models: ["synthetic-text"],
    imageGeneration: true,
    imageModels: ["synthetic-image"],
    limits: {
      tokens: null,
      active: null,
    },
    createdAtUnixSeconds: 1,
    archivedAtUnixSeconds: null,
  };
  let policy: unknown;
  const queries: string[] = [];
  await page.route("**/api/session", (route) =>
    route.fulfill({
      json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
    }),
  );
  await page.route("**/api/keys**", async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/keys/options")
      return route.fulfill({
        json: { models: ["synthetic-text"], imageModels: ["synthetic-image"] },
      });
    if (url.pathname === "/api/keys") {
      queries.push(url.search);
      return route.fulfill({
        json: {
          keys:
            (url.searchParams.get("archived") === "true") ===
            (key.archivedAtUnixSeconds != null)
              ? [key]
              : [],
          nextCursor: null,
        },
      });
    }
    const body = route.request().postDataJSON();
    expect(body.revision).toBe(key.revision);
    if (url.pathname.endsWith("/archive"))
      key = { ...key, archivedAtUnixSeconds: 100, revision: key.revision + 1 };
    else if (url.pathname.endsWith("/unarchive"))
      key = {
        ...key,
        archivedAtUnixSeconds: null,
        enabled: false,
        revision: key.revision + 1,
      };
    else {
      policy = body;
      key = { ...key, ...body, revision: key.revision + 1 };
    }
    return route.fulfill({ json: { key } });
  });
  await page.goto("/#/keys");
  await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
  await page.getByRole("button", { name: "查看详情" }).click();
  const blocked = page.getByRole("button", { name: "归档" });
  await expect(blocked).toBeDisabled();
  await expect(blocked).toHaveAttribute("title", "请先禁用密钥，再归档");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "查看详情" }).click();
  for (const name of ["对话模型范围", "图片模型范围"]) {
    const scope = page.getByRole("radiogroup", { name });
    await scope
      .getByRole("radio", {
        name:
          name === "对话模型范围"
            ? "全部模型（跟随目录）"
            : "全部模型（跟随配置）",
      })
      .check();
    await expect(
      scope.getByRole("radio", { name: "指定模型" }),
    ).not.toBeChecked();
  }
  await page.screenshot({
    path: testInfo.outputPath("all-model-scopes.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByRole("button", { name: "保存修改" })).toBeHidden();
  expect(policy).toMatchObject({ models: null, imageModels: null });
  await expect(page.getByText("全部模型", { exact: true })).toBeVisible();
  await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
  await page.getByRole("button", { name: "查看详情" }).click();
  await page.getByRole("button", { name: "禁用", exact: true }).click();
  await page.getByRole("button", { name: "确认禁用" }).click();
  await expect(page.getByRole("button", { name: "确认禁用" })).toBeHidden();
  await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
  await expect(page.getByRole("button", { name: "查看详情" })).toBeHidden();
  await page.getByRole("combobox", { name: "可用状态", exact: true }).click();
  await page.getByRole("option", { name: "已禁用", exact: true }).click();
  await page.getByRole("button", { name: "查看详情" }).click();
  await page.getByRole("button", { name: "归档", exact: true }).click();
  await expect(
    page.getByText(/归档后从默认列表隐藏，用量统计和审计保留/),
  ).toBeVisible();
  await page.getByRole("button", { name: "确认归档" }).click();
  await expect(page.getByRole("button", { name: "查看详情" })).toBeHidden();
  await page.getByRole("combobox", { name: "可用状态", exact: true }).click();
  await page.getByRole("option", { name: "已归档", exact: true }).click();
  await expect(page.getByRole("button", { name: "查看详情" })).toBeVisible();
  expect(queries).toContain("?archived=true");
  await page.screenshot({
    path: testInfo.outputPath("archived-desktop.png"),
    fullPage: true,
  });
  await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
  await page.getByRole("button", { name: "查看详情" }).click();
  await page.getByRole("button", { name: "恢复", exact: true }).click();
  await expect(
    page.getByText("恢复后仍为停用状态，需要单独启用。"),
  ).toBeVisible();
  await page.getByRole("button", { name: "确认恢复" }).click();
  await expect(page.getByRole("button", { name: "查看详情" })).toBeHidden();
  await page.getByRole("combobox", { name: "可用状态", exact: true }).click();
  await page.getByRole("option", { name: "已禁用", exact: true }).click();
  await expect(page.getByRole("button", { name: "查看详情" })).toBeVisible();
  expect(key.enabled).toBe(false);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: testInfo.outputPath("restored-mobile.png"),
    fullPage: true,
  });
  await expectNoHorizontalOverflow(page);
});
