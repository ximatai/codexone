import { expect, test } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";

test("O01 O03: anchors reminders to objects and bounds fifty reminders", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  await page.getByRole("link", { name: /team-201：访问密钥/ }).click();
  await expect(page).toHaveURL(/target=synthetic-key-201/);
  const row = page.locator('[data-row-id="synthetic-key-201"]');
  await expect(row).toHaveAttribute("data-highlighted", "true");
  await expect(row).toBeInViewport();
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  await page
    .getByRole("link", { name: /合成账号 1：账号需要重新授权/ })
    .click();
  await expect(page.getByRole("dialog", { name: "账号详情" })).toContainText(
    "合成账号 1",
  );
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  state.alerts = 50;
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  await page.getByRole("button", { name: "刷新请求概览" }).click();
  await expect(
    page.getByText("共 50 项 · 紧急 1 项 · 提醒 49 项"),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: /team-201：访问密钥/ }),
  ).toHaveCount(4);
  await expect(page.getByLabel("关键指标")).toBeInViewport();
  await page.getByRole("button", { name: "查看全部 50 项" }).click();
  await expect(
    page.getByRole("link", { name: /team-201：访问密钥/ }),
  ).toHaveCount(49);
  await page.getByRole("button", { name: "收起提醒" }).click();
});

test("O02 A03 K09: 503 and 429 never masquerade as successful empty lists", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.failures["/api/usage/in-flight"] = 503;
  state.failures["/api/usage"] = 503;
  await page.goto("/");
  await expect(page.getByText("进行中请求读取失败。请重试。")).toBeVisible();
  await expect(page.getByText("最近请求读取失败。请重试。")).toBeVisible();
  await expect(page.getByText("当前没有进行中的请求。")).toHaveCount(0);
  await expect(page.getByText("暂无已结束的请求。")).toHaveCount(0);
  for (const status of [503, 429]) {
    state.failures["/api/accounts"] = status;
    await page.goto("/#/accounts");
    await expect(page.getByText(/账号读取失败/)).toBeVisible();
    await expect(page.getByText(/接入第一个账号/)).toHaveCount(0);
    state.failures["/api/keys"] = status;
    await page.goto("/#/keys");
    await expect(page.getByText("数量不可用")).toBeVisible();
    await expect(page.getByText("暂无未归档密钥。")).toHaveCount(0);
    await expect(page.getByText("共 0 个")).toHaveCount(0);
  }
  state.failures = {};
  state.empty = true;
  await page.reload();
  await expect(page.getByText("暂无未归档密钥。")).toBeVisible();
  await expect(page.getByText("共 0 个")).toBeVisible();
  await page.goto("/#/accounts");
  await expect(page.getByText(/接入第一个账号/)).toBeVisible();
  await page.goto("/");
  await expect(page.getByText("当前没有进行中的请求。")).toBeVisible();
  await expect(page.getByText("暂无已结束的请求。")).toBeVisible();
});

test("A01 A02: long account names fit all viewports and authorization warns independently", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/#/accounts");
  const unknown = page.getByText("授权结果未知", { exact: true });
  const reauth = page.getByText("需要重新授权", { exact: true });
  expect(
    await unknown
      .locator("..")
      .evaluate((element) =>
        (element as HTMLElement).style.getPropertyValue("--badge-color"),
      ),
  ).toContain("yellow");
  expect(
    await reauth
      .locator("..")
      .evaluate((element) =>
        (element as HTMLElement).style.getPropertyValue("--badge-color"),
      ),
  ).toContain("red");
  for (const [width, height] of [
    [1440, 900],
    [1920, 1080],
    [1280, 800],
    [390, 844],
  ]) {
    await page.setViewportSize({ width, height });
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth),
    ).toBe(width);
    const name = page.getByText("LongUnbrokenAccountDisplayName".repeat(2), {
      exact: true,
    });
    const fits = await name.evaluate((element) => {
      const parent = element
        .closest(".mantine-Paper-root")!
        .getBoundingClientRect();
      const rect = element.getBoundingClientRect();
      return (
        rect.left >= parent.left &&
        rect.right <= parent.right &&
        element.scrollWidth <= element.clientWidth
      );
    });
    expect(fits).toBe(true);
  }
});

test("K03 K04 K06: confirms target, preserves exact expiry and handles summary failure", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  const expires = Date.parse("2026-11-03T12:42:56Z") / 1000;
  state.keys[0].expiresAtUnixSeconds = expires;
  await page.goto("/#/keys?q=team-0");
  await expect(page.getByText("2026-11-03 12:42:56 UTC")).toBeVisible();
  await page
    .getByRole("button", { name: "team-0 更多操作", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "轮换", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "轮换 API Key" });
  await expect(dialog).toContainText("team-0");
  await expect(dialog.getByLabel("密钥完整 ID")).toHaveValue("synthetic-key-0");
  await expect(dialog).toContainText("当前开关：启用");
  await dialog.getByRole("button", { name: "取消" }).click();
  await page
    .getByRole("button", { name: "team-0 更多操作", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "设置到期时间" }).click();
  await page.getByRole("button", { name: "保存到期时间" }).click();
  await expect.poll(() => state.writes.length).toBe(1);
  expect(state.writes[0].body.expiresAtUnixSeconds).toBe(expires);
  state.failures["/api/usage/keys"] = 503;
  await page.getByRole("button", { name: "刷新列表" }).click();
  await expect(page.getByText(/今日摘要读取失败/)).toBeVisible();
  await expect(page.locator("tbody")).not.toContainText("从未使用");
  await expect(page.locator("tbody")).toContainText("最近：不可用");
});

test("K01 K02 K05: availability filters, pagination top, sticky header and back restoration", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  state.keys[3].expiresAtUnixSeconds = Math.floor(Date.now() / 1000) + 86400;
  await page.goto("/#/keys");
  await expect(page.locator("tbody tr")).toHaveCount(50);
  await page.getByLabel("可用状态", { exact: true }).selectOption("available");
  await expect(page.locator("tbody")).not.toContainText("已到期");
  await page.getByLabel("可用状态", { exact: true }).selectOption("expiring");
  await expect(page.getByText("team-3", { exact: true })).toHaveCount(0);
  await page.getByLabel("可用状态", { exact: true }).selectOption("expired");
  await expect(page.locator("tbody tr").first()).toContainText("已到期");
  await page.getByLabel("可用状态", { exact: true }).selectOption("");
  await expect(page).toHaveURL(/#\/keys$/);
  // Both the expired and unfiltered first pages have 50 rows. The URL can
  // update before React commits the new filter, so also wait for its controls.
  await expect(page.getByLabel("可用状态", { exact: true })).toHaveValue("");
  await expect(page.getByText("共 204 个", { exact: true })).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(50);
  await page.getByRole("button", { name: "下一页", exact: true }).click();
  await expect(page).toHaveURL(/page=2/);
  await expect(page.locator("table").locator("..")).toBeFocused();
  await expect
    .poll(() =>
      page
        .locator("table")
        .evaluate((table) => table.getBoundingClientRect().top),
    )
    .toBeLessThan(120);
  expect(
    await page
      .locator("table")
      .evaluate((table) => table.getBoundingClientRect().top),
  ).toBeGreaterThan(63);
  await page.evaluate(() => window.scrollBy(0, 500));
  expect(
    await page
      .locator("td")
      .first()
      .evaluate((td) => getComputedStyle(td).position),
  ).toBe("static");
  expect(
    await page
      .locator("th")
      .first()
      .evaluate((th) => getComputedStyle(th).position),
  ).toBe("sticky");
  expect(
    await page
      .locator("th")
      .first()
      .evaluate((th) => th.getBoundingClientRect().top),
  ).toBe(64);
  await page.getByLabel("搜索主体名", { exact: true }).fill("team-201");
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "用量与诊断", exact: true }),
  ).toBeVisible();
  await page.goBack();
  await expect(page.getByLabel("搜索主体名", { exact: true })).toHaveValue(
    "team-201",
  );
  await expect(page.locator("tbody tr")).toHaveCount(1);
});

test("U02 U03: usage page turns start at the list and back retains page and position", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.goto("/#/usage");
  await expect(page.getByText("第 1 页", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "下一页", exact: true }).click();
  await expect(page.getByText("第 2 页", { exact: true })).toBeAttached();
  await expect(
    page.getByRole("heading", { name: "请求明细" }),
  ).toBeInViewport();
  await expect(page).toHaveURL(/page=2/);
  await page.evaluate(() => window.scrollBy(0, 500));
  const scroll = await page.evaluate(() => window.scrollY);
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "访问密钥", exact: true }),
  ).toBeVisible();
  await page.goBack();
  await expect(page.getByText("第 2 页", { exact: true })).toBeAttached();
  await expect(page.getByText("request-50", { exact: true })).toBeAttached();
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(scroll);
  expect(new URL(page.url()).hash).not.toContain("cursor");
});

test("K07 K08 L01 L02: past-time warning, exact thresholds and discoverable busy login", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  await page.goto("/#/keys");
  await page.getByRole("button", { name: "创建密钥", exact: true }).click();
  const drawer = page.getByRole("dialog", { name: "创建密钥", exact: true });
  await drawer.getByLabel("到期时间", { exact: true }).selectOption("custom");
  await drawer
    .getByLabel("到期日期（UTC）", { exact: true })
    .fill("2020-01-01");
  await expect(
    drawer.getByText("所选时间已过去，保存后立即拒绝新请求。"),
  ).toBeVisible();
  await drawer.getByRole("button", { name: /本地治理限额/ }).click();
  await drawer
    .getByLabel("每日估算阈值（美元）", { exact: true })
    .fill("0.000001");
  await drawer.getByRole("button", { name: /本地治理限额/ }).click();
  await expect(
    drawer.getByRole("button", { name: /本地治理限额/ }),
  ).toContainText("每日 $0.000001");
  await drawer.getByRole("button", { name: "取消", exact: true }).click();
  await page
    .getByRole("button", { name: "team-0 更多操作", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "设置到期时间" }).click();
  await page.getByLabel("到期日期（UTC）", { exact: true }).fill("2020-01-01");
  await expect(
    page.getByText("所选时间已过去，保存后立即拒绝新请求。"),
  ).toBeVisible();
  await page.getByRole("button", { name: "关闭", exact: true }).click();
  state.anonymous = true;
  await page.goto("/");
  await page.getByRole("button", { name: "管理员登录", exact: true }).click();
  state.failures["/api/session"] = 429;
  await page.getByLabel("管理员凭证", { exact: true }).fill("synthetic-login");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await expect(
    page.getByText("管理服务繁忙，请稍候再手动重试登录。"),
  ).toBeVisible();
  await expect(page.getByLabel("管理员凭证", { exact: true })).toHaveValue("");
});
