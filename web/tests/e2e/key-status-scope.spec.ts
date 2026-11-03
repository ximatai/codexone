import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
for (const width of [1440, 390]) {
  test(`Key scope defaults available and all includes archived at ${width}px`, async ({
    page,
  }) => {
    const state = await reviewFixture(page);
    const active = {
      ...state.keys[0],
      displayName: "合成可用",
      expiresAtUnixSeconds: null,
    };
    const disabled = {
      ...active,
      id: "synthetic-disabled",
      displayName: "合成禁用",
      enabled: false,
    };
    const archived = {
      ...disabled,
      id: "synthetic-archived",
      displayName: "合成归档",
      archivedAtUnixSeconds: 1,
    };
    await page.route("**/api/keys?*", async (route) => {
      const url = new URL(route.request().url());
      return route.fulfill({
        json: {
          keys:
            url.searchParams.get("archived") === "true"
              ? [archived]
              : [active, disabled],
          nextCursor: null,
        },
      });
    });
    await page.route("**/api/keys", (route) =>
      route.fulfill({ json: { keys: [active, disabled], nextCursor: null } }),
    );
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/#/keys");
    const select = page.getByRole("combobox", { name: "可用状态" });
    await expect(select).toHaveValue("可用");
    await expect(page.getByText("合成可用", { exact: true })).toBeVisible();
    await expect(page.getByText("合成归档", { exact: true })).toHaveCount(0);
    await expect(page.getByText("合成禁用", { exact: true })).toHaveCount(0);
    await select.click();
    await page.getByRole("option", { name: "全部", exact: true }).click();
    await expect(page.getByText("合成归档", { exact: true })).toBeVisible();
    await expect(page.getByText("合成禁用", { exact: true })).toBeVisible();
    await page.reload();
    await expect(select).toHaveValue("全部");
    await expect(page.getByText("合成归档", { exact: true })).toBeVisible();
    await select.click();
    await page.getByRole("option", { name: "已归档", exact: true }).click();
    await expect(page.getByText("合成归档", { exact: true })).toBeVisible();
    await expect(page.getByText("合成可用", { exact: true })).toHaveCount(0);
  });
}
