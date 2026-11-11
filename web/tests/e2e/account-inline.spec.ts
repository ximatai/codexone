import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";

test("overview opens account details in place and preserves scroll, navigation and history", async ({
  page,
}) => {
  test.setTimeout(30_000);
  await reviewFixture(page);
  await page.setViewportSize({ width: 1920, height: 1680 });
  await page.goto("/");
  const link = page
    .getByLabel("订阅额度与系统状态")
    .getByRole("link", { name: "合成账号 3", exact: true });
  await link.scrollIntoViewIfNeeded();
  const top = await page.evaluate(() => scrollY);
  await link.click();
  const drawer = page.getByRole("dialog", { name: "账号详情" });
  await expect(drawer).toContainText("合成账号 3");
  await expect(page).toHaveURL(/#\/\?account=synthetic-account-3/);
  await expect(
    page
      .getByRole("navigation", { name: "控制台导航" })
      .getByRole("link", { name: /服务概览/ }),
  ).toHaveAttribute("aria-current", "page");
  await expect(
    page
      .getByRole("navigation", { name: "控制台导航" })
      .getByRole("link", { name: "订阅账号", exact: true }),
  ).not.toHaveAttribute("aria-current", "page");
  await page.goBack();
  await expect(drawer).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => scrollY)).toBeCloseTo(top, 0);
  await page.goForward();
  await expect(drawer).toContainText("合成账号 3");
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(drawer).toHaveCount(0);
  await expect(page).not.toHaveURL(/account=/);
  await expect.poll(() => page.evaluate(() => scrollY)).toBeCloseTo(top, 0);
});

test("overview account deep links survive reload and report missing accounts inside the drawer", async ({
  page,
}) => {
  test.setTimeout(30_000);
  await reviewFixture(page);
  await page.goto("/#/?account=synthetic-account-2&extra=keep");
  const drawer = page.getByRole("dialog", { name: "账号详情" });
  await expect(drawer).toContainText("合成账号 2", { timeout: 10_000 });
  await page.reload();
  await expect(drawer).toContainText("合成账号 2", { timeout: 10_000 });
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(page).toHaveURL(/#\/\?extra=keep/);
  await page.goto("/#/?account=synthetic-missing");
  await expect(drawer).toContainText("目标账号已不存在或不在当前账号列表中。");
  await expect(page).toHaveURL(/#\/\?account=synthetic-missing/);
});

test("unconfigured account management reports its state inside the overview drawer", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.failures["/api/accounts"] = 404;
  await page.goto("/#/?account=synthetic-account-1");
  await expect(page.getByRole("dialog", { name: "账号详情" })).toContainText(
    "账号接入尚未开启，无法读取账号详情。",
  );
  await expect(page).toHaveURL(/#\/\?account=synthetic-account-1/);
});

test("editing an account inside the overview refreshes its account card without navigating", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  const account = state.accounts[3];
  await page.route(
    "**/api/accounts/synthetic-account-3/display-name",
    async (route) => {
      const body = route.request().postDataJSON();
      account.displayName = body.displayName;
      account.revision++;
      await route.fulfill({ json: { account } });
    },
  );
  await page.goto("/#/?account=synthetic-account-3");
  const drawer = page.getByRole("dialog", { name: "账号详情" });
  await drawer.getByRole("tab", { name: "设置", exact: true }).click();
  await drawer.getByLabel("账号显示名", { exact: true }).fill("首页内修改");
  await drawer.getByRole("button", { name: "保存显示名", exact: true }).click();
  await expect(drawer.getByText("首页内修改", { exact: true })).toBeVisible();
  await expect(page).toHaveURL(/#\/\?account=synthetic-account-3/);
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();
  await expect(
    page
      .getByLabel("订阅额度与系统状态")
      .getByRole("link", { name: "首页内修改", exact: true }),
  ).toBeVisible();
});
