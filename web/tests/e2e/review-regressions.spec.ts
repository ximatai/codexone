import { expect, test, gotoUsage } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";

test("invalid Key name and model permissions show field errors and recover", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  await page.goto("/#/keys?q=team-0");
  await page
    .locator("tbody tr")
    .first()
    .getByRole("button", { name: "查看详情" })
    .click();
  const drawer = page.getByRole("dialog", { name: "密钥详情" });
  const name = drawer.getByRole("textbox", { name: "显示名", exact: true });
  await name.fill("invalid\u200bname");
  await drawer.getByRole("button", { name: "保存修改" }).click();
  await expect(
    drawer.getByText("显示名须为1–64个Unicode标量，且不含控制字符"),
  ).toBeVisible();
  expect(state.writes).toHaveLength(0);
  await name.fill("合成设备");
  await drawer
    .getByRole("checkbox", { name: "synthetic-text", exact: true })
    .uncheck();
  await drawer.getByRole("button", { name: "保存修改" }).click();
  await expect(drawer.getByText("请选择对话模型或图片生成权限")).toBeVisible();
  expect(state.writes).toHaveLength(0);
  await drawer
    .getByRole("checkbox", { name: "synthetic-text", exact: true })
    .check();
  await drawer.getByRole("button", { name: "保存修改" }).click();
  await expect(drawer).toBeHidden();
  expect(state.writes).toHaveLength(1);
});

for (const width of [1920, 390]) {
  test(`a hidden invalid date reopens on query and can be corrected at ${width}px`, async ({
    page,
  }) => {
    const state = await reviewFixture(page);
    await page.setViewportSize({ width, height: 900 });
    await gotoUsage(page);
    await expect(page.getByText("第 1 页", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "自定义", exact: true }).click();
    const start = page.getByRole("textbox", {
      name: "起始日（UTC）",
      exact: true,
    });
    const original = await start.inputValue();
    await start.fill("2026-02-30");
    await page.getByRole("button", { name: "自定义", exact: true }).click();
    await expect(start).not.toBeVisible();
    await page
      .getByRole("combobox", { name: "模型", exact: true })
      .fill("synthetic-other");
    const reads = state.reads.filter((r) => r.path === "/api/usage").length;
    await page.getByRole("button", { name: "查询用量", exact: true }).click();
    await expect(start).toBeVisible();
    await expect(page.getByText("请输入有效日期（YYYY-MM-DD）")).toBeVisible();
    expect(state.reads.filter((r) => r.path === "/api/usage")).toHaveLength(
      reads,
    );
    await start.fill(original);
    await start.press("Tab");
    await page.getByRole("button", { name: "查询用量", exact: true }).click();
    await expect(page).toHaveURL(/model=synthetic-other/);
    await expect
      .poll(() => state.reads.filter((r) => r.path === "/api/usage").length)
      .toBe(reads + 1);
    await expect(page.locator("tbody tr")).toHaveCount(10);
  });
}
