import { expect, test, gotoUsage } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";

test("P2-1: collapsing fifty reminders returns the toggle to view with focus", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.alerts = 50;
  await page.goto("/");
  await page.getByRole("button", { name: "查看全部 50 项" }).click();
  await page.getByRole("button", { name: "收起提醒" }).click();
  const toggle = page.getByRole("button", { name: "查看全部 50 项" });
  await expect(toggle).toBeFocused();
  await expect(toggle).toBeInViewport();
});

test("P2-2 Key: POP restores page/query/position and sidebar entry starts at the URL top", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/#/keys?q=team");
  await page.getByRole("button", { name: "下一页", exact: true }).click();
  await expect(page).toHaveURL(/page=2/);
  await expect(page.locator("table").locator("..")).toBeFocused();
  await page.evaluate(() => scrollTo(0, 1800));
  const position = await page.evaluate(() => scrollY);
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  await page.goBack();
  await expect(page).toHaveURL(/page=2/);
  await expect(page.getByLabel("搜索主体名", { exact: true })).toHaveValue(
    "team",
  );
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(position);
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(page.getByLabel("搜索主体名", { exact: true })).toHaveValue("");
  await expect(page.getByText("第 1 / 5 页 · 每页 50 个")).toBeAttached();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
});

test("P2-2 Usage: pages keep separate POP positions and fresh entry ignores page two memory", async ({
  page,
}) => {
  await reviewFixture(page);
  await gotoUsage(page);
  await page.getByRole("button", { name: "下一页", exact: true }).click();
  await expect(page.getByText("第 2 页", { exact: true })).toBeAttached();
  await page.evaluate(() => scrollTo(0, 1800));
  const position = await page.evaluate(() => scrollY);
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await page.goBack();
  await expect(page.getByText("request-50", { exact: true })).toBeAttached();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(position);
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  await expect(page.getByText("第 1 页", { exact: true })).toBeAttached();
  await expect(page.getByText("request-0", { exact: true })).toBeAttached();
  await expect.poll(() => page.evaluate(() => scrollY)).toBe(0);
});

test("P2-3: first Key failure has one error and one in-table retry", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.failures["/api/keys"] = 503;
  await page.goto("/#/keys");
  await expect(page.getByRole("alert")).toHaveCount(1);
  await expect(
    page.getByRole("button", { name: "重试", exact: true }),
  ).toHaveCount(1);
  state.failures = {};
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.locator("tbody tr")).toHaveCount(50);
});

test("P2-4: first failure has no snapshot claim and overview merges failing sources", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.failures["/api/usage"] = 503;
  await gotoUsage(page);
  await expect(page.getByRole("alert")).toContainText("查询失败或繁忙");
  await expect(page.getByRole("alert")).not.toContainText("快照");
  for (const path of [
    "/api/accounts",
    "/api/usage/keys",
    "/api/runtime/storage",
    "/api/attention",
    "/api/usage/daily",
    "/api/usage/in-flight",
    "/api/usage/headroom",
  ])
    state.failures[path] = 503;
  await page.goto("/");
  await expect(page.getByRole("alert")).toHaveCount(1);
  const alert = page.getByRole("alert");
  for (const source of [
    "运营指标",
    "进行中请求",
    "最近请求",
    "订阅账号",
    "Key 用量摘要",
    "存储状态",
    "需要处理提醒",
    "治理余量",
  ])
    await expect(alert).toContainText(source);
  await expect(alert).not.toContainText("快照");
  state.failures = {};
  await page.getByRole("button", { name: "重试", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveCount(2); // two actual attention items
  state.alerts = 0;
  state.failures["/api/usage/daily"] = 503;
  state.failures["/api/usage/in-flight"] = 503;
  await page.getByRole("button", { name: "刷新请求概览" }).click();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await expect(page.getByRole("alert")).toContainText(/保留上次成功快照 \d{4}/);
});

for (const status of [503, 429]) {
  test(`P2-5: ${status} page failure stays beside pagination and retries the failed cursor`, async ({
    page,
  }) => {
    const state = await reviewFixture(page);
    await gotoUsage(page);
    await expect(page.getByText("第 1 页", { exact: true })).toBeAttached();
    state.failures["/api/usage"] = status;
    await page.getByRole("button", { name: "下一页", exact: true }).click();
    const retry = page.getByRole("button", { name: "重试翻页" });
    await expect(retry).toBeVisible();
    await expect(retry).toBeInViewport();
    await expect(page.getByRole("alert")).toContainText("第 2 页读取失败");
    await expect(page.getByRole("alert")).toContainText("保留上次成功快照");
    await expect(
      page.getByRole("button", { name: "下一页", exact: true }),
    ).toBeEnabled();
    const failed = state.reads.filter((r) => r.path === "/api/usage").at(-1)!;
    state.failures = {};
    await retry.click();
    await expect(page.getByText("request-50", { exact: true })).toBeAttached();
    await expect(page.getByText("第 2 页", { exact: true })).toBeAttached();
    expect(state.reads.filter((r) => r.path === "/api/usage").at(-1)).toEqual(
      failed,
    );
  });
}

test("P2-6: login, Key targets and cancel/Escape transfer focus to the intended controls", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.anonymous = true;
  await page.goto("/");
  await page.getByRole("button", { name: "管理员登录", exact: true }).click();
  await expect(page.getByLabel("管理员凭证", { exact: true })).toBeFocused();
  state.anonymous = false;
  await page.goto("/");
  await page.getByRole("link", { name: /team-201：访问密钥/ }).click();
  const row = page.getByRole("row", { name: /访问密钥 team-201/ });
  await expect(row).toBeFocused();
  const create = page.getByRole("button", { name: "创建密钥", exact: true });
  await create.click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "取消", exact: true })
    .click();
  await expect(create).toBeFocused();
  const more = row.getByRole("button", { name: "team-201 更多操作" });
  for (const close of ["cancel", "escape"]) {
    await more.click();
    await page.getByRole("menuitem", { name: "轮换", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "轮换 API Key" });
    await expect(dialog).toBeVisible();
    if (close === "cancel")
      await dialog.getByRole("button", { name: "取消" }).click();
    else await page.keyboard.press("Escape");
    await expect(more).toBeFocused();
  }
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  const detail = page
    .getByRole("button", { name: "查看详情", exact: true })
    .first();
  await detail.click();
  await expect(page.getByRole("dialog", { name: "请求详情" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(detail).toBeFocused();
});

test("Colors: expired switches are neutral, disclosure links use primary and abnormal accounts warn", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/#/keys?status=expired");
  const enabled = page
    .locator("tbody tr")
    .first()
    .getByText("启用", { exact: true })
    .locator("..");
  expect(
    await enabled.evaluate((e) =>
      (e as HTMLElement).style.getPropertyValue("--badge-color"),
    ),
  ).toContain("gray");
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  const summary = page.getByText("更多筛选", { exact: true });
  const primaryColor = await page
    .getByRole("button", { name: "查询用量", exact: true })
    .evaluate((e) => getComputedStyle(e).backgroundColor);
  expect(await summary.evaluate((e) => getComputedStyle(e).color)).toBe(
    primaryColor,
  );
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  const dot = page.getByRole("link", { name: /可用账号/ }).locator("span");
  expect(await dot.evaluate((e) => (e as HTMLElement).style.color)).toContain(
    "orange",
  );
});

test("Quota: an account name opens that account's details", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/");
  await page
    .getByLabel("订阅额度与系统状态")
    .getByRole("link", { name: "合成账号 3", exact: true })
    .click();
  await expect(page).toHaveURL(/accounts\?target=synthetic-account-3/);
  await expect(page.getByRole("dialog", { name: "账号详情" })).toContainText(
    "合成账号 3",
  );
});

test("P2-6 Colors: rotating an expired Key keeps focus in the secret dialog and switch neutral", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/#/keys?q=team-2&status=expired");
  const more = page.getByRole("button", {
    name: "team-2 更多操作",
    exact: true,
  });
  await more.click();
  await page.getByRole("menuitem", { name: "轮换", exact: true }).click();
  const old = page.getByRole("dialog", { name: "轮换 API Key" });
  await old.getByRole("button", { name: "确认轮换", exact: true }).click();
  const secret = page.getByRole("dialog", { name: "保存一次性凭证" });
  await expect(secret).toBeVisible();
  await expect(old).not.toBeAttached();
  await expect
    .poll(() =>
      secret.evaluate((element) => element.contains(document.activeElement)),
    )
    .toBe(true);
  expect(
    await secret
      .getByText("已启用", { exact: true })
      .locator("..")
      .evaluate((element) =>
        (element as HTMLElement).style.getPropertyValue("--badge-color"),
      ),
  ).toContain("gray");
});
