import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("round two overview, usage, account name and key expiration", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const screenshots = "/tmp/codexone-admin-round2-screenshots";
  await mkdir(screenshots, { recursive: true });
  let authenticated = false;
  const account = {
    id: "synthetic-account",
    revision: 1,
    credentialVersion: 1,
    displayName: null as string | null,
    mode: "enabled",
    authorization: "ready",
    accessExpiresAtUnixSeconds: Math.floor(Date.now() / 1000) + 10800,
    credentialUpdatedAtUnixSeconds: null,
    createdAtUnixSeconds: 1,
    observability: observationFixture(),
  };
  const key = {
    id: "alpha",
    principal: "synthetic-team",
    revision: 1,
    enabled: true,
    models: ["synthetic-text"],
    limits: {
      requests: 100,
      active: 4,
      unresolved: 8,
      budgetMicros: 1000000,
      unresolvedMicros: 1000000,
    },
    createdAtUnixSeconds: 1,
    expiresAtUnixSeconds: null as number | null,
  };
  const metrics = {
    inputTokens: "100",
    cachedTokens: "80",
    outputTokens: "20",
    images: "0",
    estimatedMicros: "1250000",
  };
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    let json: unknown;
    if (path === "/api/session") {
      if (route.request().method() === "POST") authenticated = true;
      return route.fulfill({
        status: authenticated ? 200 : 401,
        json: authenticated
          ? { authenticated: true, csrf: "ac1_" + "a".repeat(43) }
          : { error: { code: "unauthorized" } },
      });
    }
    if (path === "/api/system")
      json = { service: "codexone", ready: true, checks: [] };
    else if (path === "/api/accounts")
      json = { accounts: [account], nextCursor: null };
    else if (path === "/api/accounts/synthetic-account/display-name") {
      const body = route.request().postDataJSON();
      expect(body.revision).toBe(account.revision);
      account.displayName = body.displayName;
      account.revision++;
      json = { account };
    } else if (path === "/api/accounts/synthetic-account/observation")
      json = observationFixture();
    else if (path === "/api/runtime/storage")
      json = {
        pressure: "normal",
        admissionAllowed: true,
        optionalWorkAllowed: true,
      };
    else if (path === "/api/keys/options")
      json = { models: ["synthetic-text"], imageModels: [] };
    else if (path === "/api/keys") json = { keys: [key], nextCursor: null };
    else if (path === "/api/keys/alpha/expiration") {
      const body = route.request().postDataJSON();
      expect(body.revision).toBe(key.revision);
      key.expiresAtUnixSeconds = body.expiresAtUnixSeconds;
      key.revision++;
      json = { key };
    } else if (path === "/api/usage/keys") {
      const start = Math.floor(Date.now() / 86400000) * 86400;
      json = {
        timezone: "UTC",
        startUnixSeconds: start,
        endUnixSeconds: start + 86400,
        keys: [
          {
            keyID: key.id,
            principal: key.principal,
            admitted: 2,
            failed: 1,
            pending: 1,
            estimatedMicros: "1250000",
            lastUsedAtUnixSeconds: start,
          },
        ],
      };
    } else if (path === "/api/usage/daily")
      json = {
        timezone: "UTC",
        days: 7,
        buckets: Array.from({ length: 7 }, (_, i) => ({
          atUnixSeconds:
            Math.floor(Date.now() / 86400000) * 86400 - (6 - i) * 86400,
          requests: 10 + i,
          succeeded: 8 + i,
          failed: 2,
          cancelled: 0,
          failures: { rate_limited: 2 },
          metrics,
        })),
      };
    else if (path === "/api/usage/in-flight")
      json = {
        rows: [
          {
            id: "flight-1",
            keyID: "alpha",
            principal: "synthetic-team",
            model: "synthetic-text",
            mode: "generation",
            accountID: account.id,
            accountDisplayName: "合成进行中账号",
            startedAtUnixSeconds: Math.floor(Date.now() / 1000) - 12,
            elapsedSeconds: 12,
            hasFirstEvent: false,
          },
        ],
      };
    else if (path === "/api/usage/options")
      json = {
        keys: ["alpha"],
        keyOptions: [{ id: "alpha", principal: "synthetic-team" }],
        models: ["synthetic-text"],
        failures: [],
      };
    else if (path === "/api/usage") {
      const report = reportFixture();
      json = {
        ...report,
        nextCursor: null,
        totals: {
          ...report.totals,
          metrics,
          averageFirstEventMilliseconds: 12,
          p95FirstEventMilliseconds: 20,
          averageTotalMilliseconds: 34,
        },
        rows: report.rows.map((row) => ({
          ...row,
          metrics,
          principal: "synthetic-team",
          firstEventMilliseconds: 12,
          totalMilliseconds: 34,
        })),
      };
    } else throw new Error("Unmocked synthetic API " + path);
    return route.fulfill({ json });
  });
  await page.goto("/#/keys");
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-admin-only");
  await page.getByRole("button", { name: "登录管理台" }).click();
  await page.getByRole("link", { name: "服务概览", exact: true }).click();
  const activity = page.getByLabel("请求即时概览");
  await expect(
    activity.getByRole("img", { name: /^今日请求近 7 天：/ }),
  ).toBeVisible();
  await expect(activity.getByText("输入缓存占比 80.0%")).toBeVisible();
  await expect(activity.getByText("主要异常：上游限流（100%）")).toBeVisible();
  await expect(
    activity.getByText("合成进行中账号", { exact: false }),
  ).toBeVisible();
  await expect(
    activity.getByText("等待首事件", { exact: false }),
  ).toBeVisible();
  await expect(activity.getByText("16", { exact: true })).toBeVisible();
  await expect(activity.getByLabel("自动刷新（15 秒）")).toBeChecked();
  await activity.locator("tbody tr[tabindex]").first().click();
  await expect(page.getByRole("dialog", { name: "请求详情" })).toContainText(
    "request-first",
  );
  await page
    .getByRole("dialog", { name: "请求详情" })
    .getByRole("button", { name: "关闭", exact: true })
    .click();
  await page.screenshot({
    path: screenshots + "/overview-1440.png",
    fullPage: true,
  });
  await page.getByRole("link", { name: "用量与诊断", exact: true }).click();
  await expect(page.locator(".usage-table")).toContainText("首事件耗时");
  await expect(page.locator(".usage-table")).toContainText("总耗时");
  await expect(page.getByText("P95 首事件耗时", { exact: true })).toBeVisible();
  await page.screenshot({
    path: screenshots + "/usage-1440.png",
    fullPage: true,
  });
  await page.getByRole("link", { name: "订阅账号", exact: true }).click();
  await page.getByRole("button", { name: "额度与健康详情" }).click();
  await expect(page.getByText(/访问凭证到期：.*约 3 小时后/)).toBeVisible();
  await expect(page.getByText("最近凭证更新：不可用")).toBeVisible();
  await page.getByLabel("账号显示名").fill("合成显示名");
  await page.getByRole("button", { name: "保存显示名" }).click();
  await expect(page.getByLabel("账号显示名")).toHaveValue("合成显示名");
  await expect(page.getByRole("button", { name: "清除显示名" })).toBeEnabled();
  await page.screenshot({
    path: screenshots + "/account-1440.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "清除显示名" }).click();
  await expect(page.getByLabel("账号显示名")).toHaveValue("");
  await page
    .getByRole("dialog", { name: "账号详情" })
    .getByRole("button", { name: "关闭", exact: true })
    .click();
  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  async function openExpiration() {
    await page.getByRole("button", { name: "synthetic-team 更多操作" }).click();
    await page.getByRole("menuitem", { name: "设置到期时间" }).click();
  }
  await openExpiration();
  const expiry = page.getByRole("dialog", { name: "设置 Key 到期时间" });
  await expiry.getByRole("button", { name: "+30 天", exact: true }).click();
  await expect(expiry.getByLabel("到期日期（UTC）")).toHaveValue(
    new Date(Date.now() + 31 * 86400000).toISOString().slice(0, 10),
  );
  await expiry.getByRole("button", { name: "+90 天", exact: true }).click();
  await expect(expiry.getByLabel("到期日期（UTC）")).toHaveValue(
    new Date(Date.now() + 91 * 86400000).toISOString().slice(0, 10),
  );
  await expiry
    .getByLabel("到期日期（UTC）")
    .fill(new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10));
  await expiry.getByRole("button", { name: "保存到期时间" }).click();
  await expect(page.getByText("7 天内到期", { exact: true })).toBeVisible();
  await page.screenshot({
    path: screenshots + "/key-expiration-1440.png",
    fullPage: true,
  });
  await openExpiration();
  await expiry.getByRole("button", { name: "清除到期时间" }).click();
  await expect(page.getByText("永不过期", { exact: true })).toBeVisible();
  expect(key.expiresAtUnixSeconds).toBeNull();
});
