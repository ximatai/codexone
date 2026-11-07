import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("overview keeps accessible trends, principal names, details and responsive layout", async ({
  page,
}) => {
  await page.clock.install();
  await page.setViewportSize({ width: 1440, height: 900 });
  const screenshots = "../artifacts/ui-phase2";
  await mkdir(screenshots, { recursive: true });
  let inFlightCount = 5;
  const now = Math.floor(Date.now() / 1000);
  const today = Math.floor(now / 86400) * 86400;
  const observation = observationFixture();
  const quota = observation.quota;
  quota.observedAtUnixSeconds = now - 10;
  quota.attemptedAtUnixSeconds = now - 10;
  quota.limits[0].primary.usedPercent = 38;
  quota.limits[0].primary.resetsAtUnixSeconds = now + 7200;

  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const metrics = {
      inputTokens: "1200",
      cachedTokens: "800",
      outputTokens: "300",
      images: "0",
      estimatedMicros: "1250000",
    };
    const account = {
      id: "synthetic-account",
      displayName: "合成订阅账号",
      revision: 1,
      credentialVersion: 1,
      mode: "enabled",
      authorization: "ready",
      createdAtUnixSeconds: 1,
      observability: {
        ...observation,
        quota: {
          ...quota,
          limits: [
            {
              ...quota.limits[0],
              secondary: {
                usedPercent: 69,
                durationSeconds: 604800,
                resetsAtUnixSeconds: now + 259200,
              },
            },
          ],
        },
      },
    };
    const report = reportFixture();
    const data: Record<string, unknown> = {
      "/api/usage/headroom": {
        capacities: [],
        accounts: [
          {
            id: account.id,
            current: 2,
            limit: 16,
            peak24Hours: 3,
            blocking: true,
          },
        ],
        unknownReconciliation: {
          count: 0,
          beforeUnixSeconds: 1,
          periodSeconds: 86400,
        },
      },
      "/api/attention": {
        generatedAtUnixSeconds: 1,
        items: [
          {
            kind: "account_requires_auth",
            severity: "critical",
            subjectType: "account",
            subjectID: account.id,
            subjectName: "合成订阅账号",
            detail: {},
            sinceUnixSeconds: 1,
          },
          {
            kind: "key_expiring",
            severity: "warning",
            subjectType: "key",
            subjectID: "synthetic-key",
            subjectName: "合成工作站",
            detail: {},
            sinceUnixSeconds: 1,
          },
          {
            kind: "client_protocol_extension",
            severity: "warning",
            subjectType: "protocol",
            subjectID: null,
            subjectName: "x-codex-" + "n".repeat(120),
            detail: { overflow: false },
            sinceUnixSeconds: 1,
          },
        ],
      },
      "/api/session": { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      "/api/system": {
        service: "codexone",
        ready: true,
        checks: [{ name: "execution_store", ready: true }],
      },
      "/api/accounts": { accounts: [account], nextCursor: null },
      "/api/runtime/storage": {
        admissionAllowed: true,
        optionalWorkAllowed: true,
        pressure: "normal",
        databaseBytes: 1024000,
        availableBytes: 36 * 1024 ** 3,
        volumeTotalBytes: 100 * 1024 ** 3,
        resources: Array.from({ length: 121 }, (_, i) => ({
          unixSeconds: now - 3600 + i * 30,
          hostCPUPercent: i === 120 ? 27 : 24 + Math.round(9 * Math.sin(i / 5)),
          processResidentBytes:
            (280 + Math.round(14 * Math.sin(i / 11))) * 1024 ** 2,
          hostAvailableBytes: (5 + Math.sin(i / 9) * 0.5) * 1024 ** 3,
          hostTotalBytes: 8 * 1024 ** 3,
        })),
      },
      "/api/usage/keys": {
        timezone: "UTC",
        startUnixSeconds: today,
        endUnixSeconds: today + 86400,
        keys: [
          {
            keyID: "synthetic-key",
            principal: "合成工作站",
            admitted: 8,
            succeeded: 7,
            cancelled: 0,
            inFlight: 0,
            failed: 1,
            pending: 0,
            estimatedMicros: "1250000",
            lastUsedAtUnixSeconds: now - 60,
            tokens: "1500",
          },
        ],
      },
      "/api/usage/daily": {
        timezone: "UTC",
        days: 7,
        buckets: Array.from({ length: 7 }, (_, i) => ({
          atUnixSeconds: today + (i - 6) * 86400,
          requests: 10 + i * 2,
          recordedRejections: i,
          succeeded: 9 + i * 2,
          failed: 1,
          cancelled: 0,
          failures: { rate_limited: 1 },
          metrics,
        })),
      },
      "/api/usage/in-flight": {
        rows: Array.from({ length: inFlightCount }, (_, index) => ({
          id: "synthetic-flight-" + index,
          startedAtUnixSeconds: index + 1,
          keyID: "hidden-key-identifier",
          principal: "合成工作站",
          model: "synthetic-text",
          mode: "generation",
          accountID: account.id,
          accountDisplayName: account.displayName,
          elapsedSeconds: 12,
          hasFirstEvent: true,
        })),
      },
      "/api/usage/options": {
        keys: ["synthetic-key"],
        models: ["synthetic-text"],
        failures: [],
      },
      "/api/usage": {
        ...report,
        nextCursor: null,
        rows: report.rows.map((row, i) => ({
          ...row,
          id: "synthetic-row-" + i,
          principal: "合成工作站",
          model: "synthetic-text",
          firstEventMilliseconds: 1200,
          totalMilliseconds: 14000,
          metrics,
        })),
      },
    };
    if (!(path in data)) throw new Error("Unexpected synthetic route: " + path);
    await route.fulfill({ json: data[path] });
  });
  await page.goto("/");
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  await expect(
    page.getByRole("heading", { name: "今日运营概览" }),
  ).toBeVisible();
  await expect(
    page.getByRole("img", { name: /^今日已准入近 7 天/ }),
  ).toBeVisible();
  const cards = page.getByLabel("在途请求卡片").locator(":scope > *");
  await expect(cards).toHaveCount(5);
  const firstRow = () =>
    cards.evaluateAll(
      (items) =>
        items.filter(
          (item) =>
            item.getBoundingClientRect().top ===
            items[0].getBoundingClientRect().top,
        ).length,
    );
  expect(await firstRow()).toBe(4);
  await expect(
    page.getByRole("img", { name: "网关内存占用最近一小时趋势" }),
  ).toBeVisible();
  const cpuGauge = page.getByRole("group", { name: "CPU 使用率" });
  await expect(cpuGauge.getByText("27%", { exact: true })).toBeVisible();
  await expect(cpuGauge.locator("circle[pathLength]")).toHaveAttribute(
    "stroke-dasharray",
    "27 100",
  );
  const memoryGauge = page.getByRole("group", { name: "服务器可用内存" });
  await expect(memoryGauge.getByText("5.3 / 8.0 GiB")).toBeVisible();
  await expect(page.getByText("窗口为上游观测，不是 Key 余额")).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "合成工作站 失败 1" }),
  ).toHaveAttribute(
    "href",
    /key=synthetic-key&start=[^&]+&end=[^&]+&outcome=failed/,
  );
  await expect(
    page.getByRole("img", { name: "服务器 CPU 使用率最近一小时趋势" }),
  ).toBeVisible();
  await expect(
    page.getByRole("img", { name: "服务器可用内存最近一小时趋势" }),
  ).toBeVisible();
  await expect(page.getByRole("group", { name: "数据盘可用" })).toContainText(
    "36%",
  );
  const shortWindow = await page
    .getByRole("progressbar", { name: "5 小时额度已用比例" })
    .boundingBox();
  const longWindow = await page
    .getByRole("progressbar", { name: "每周额度已用比例" })
    .boundingBox();
  expect(longWindow!.y).toBeGreaterThan(shortWindow!.y);
  await expect(page.getByLabel("概览连接状态")).toBeHidden();
  await expect(page.getByText("各源更新时间", { exact: true })).toBeHidden();
  await expect(
    page.getByText(/参考 60\.0% · 低于 22\.0 个百分点/),
  ).toBeVisible();
  await expect(
    page.getByText(/参考 57\.1% · 超出 11\.9 个百分点/),
  ).toBeVisible();
  await page.screenshot({
    path: screenshots + "/overview-resource-trends-1440.png",
    fullPage: true,
    animations: "disabled",
  });
  const rejected = page.getByText("已记录准入前拒绝 6");
  await expect(rejected).toBeVisible();
  const viewport = page.viewportSize()!;
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await firstRow()).toBe(2);
  await rejected.scrollIntoViewIfNeeded();
  await expect(rejected).toBeInViewport();
  await page.getByText("运行诊断", { exact: true }).click();
  await page
    .getByRole("region", { name: "需要处理", exact: true })
    .evaluate((panel) => panel.scrollIntoView({ block: "start" }));
  await expect(page.getByRole("link", { name: /x-codex-n+/ })).toBeInViewport({
    ratio: 1,
  });
  await page.setViewportSize(viewport);
  await expect(page.getByText("hidden-key-identifier")).toHaveCount(0);
  await expect(
    page.getByRole("region", { name: "需要处理", exact: true }),
  ).toContainText("合成订阅账号：账号需要重新授权");
  await expect(
    page.getByRole("region", { name: "需要处理", exact: true }),
  ).toContainText("合成工作站：访问密钥已到期或将在 7 天内到期");
  await expect(
    page.getByRole("link", { name: "服务概览（有需要处理的事项）" }),
  ).toBeVisible();
  await expect(
    page
      .getByRole("region", { name: "需要处理", exact: true })
      .getByRole("link", { name: /账号需要重新授权/ }),
  ).toHaveAttribute("href", "#/?account=synthetic-account");
  await mkdir("../artifacts/admin-attention", { recursive: true });
  await page.screenshot({
    path: "../artifacts/admin-attention/overview.png",
  });
  await page.waitForTimeout(400);
  await page.screenshot({
    path: screenshots + "/overview-1440.png",
    fullPage: true,
  });
  await page
    .getByRole("region", { name: "今日 Key 请求汇总" })
    .getByRole("link", { name: "查看用量与诊断" })
    .click();
  await expect(
    page.getByRole("heading", { name: "用量与诊断", exact: true }),
  ).toBeVisible();
  const recent = page
    .locator(".usage-table")
    .getByRole("row")
    .filter({ hasText: "合成工作站" })
    .first();
  await expect(recent).toBeVisible();
  await recent.focus();
  await expect(recent).toBeFocused();
  await recent.press("Enter");
  await expect(page.getByRole("dialog", { name: "请求详情" })).toContainText(
    "request-first",
  );
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "关闭", exact: true })
    .click();
  await recent.click();
  await expect(page.getByRole("dialog", { name: "请求详情" })).toBeVisible();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "关闭", exact: true })
    .click();
  await page.getByRole("link", { name: "服务概览", exact: false }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await expectNoHorizontalOverflow(page);
  await page.getByText("运行诊断", { exact: true }).click();
  const longReminder = page.getByRole("link", { name: /x-codex-n+/ });
  await expect(longReminder).toBeVisible();
  expect(
    await longReminder.evaluate(
      (node) =>
        node.parentElement!.scrollWidth <= node.parentElement!.clientWidth,
    ),
  ).toBeTruthy();
  await page.getByText("运行诊断", { exact: true }).click();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(350);
  await page.screenshot({
    path: screenshots + "/overview-390.png",
    fullPage: true,
  });
  inFlightCount = 0;
  await page.clock.runFor(15000);
  await expect(cards).toHaveCount(0);
  await expect(page.getByText("当前没有进行中的请求。")).toBeVisible();
});
