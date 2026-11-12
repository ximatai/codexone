import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "./fixtures";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("overview keeps accessible trends, principal names, details and responsive layout", async ({
  page,
}) => {
  test.setTimeout(30_000);
  await page.clock.install();
  await page.setViewportSize({ width: 1440, height: 900 });
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
          ...[
            "response.metadata",
            "responsesapi.websocket_timing",
            "synthetic.earlier",
          ].map((name, index) => ({
            kind: "client_protocol_extension",
            severity: "warning",
            subjectType: "protocol",
            subjectID: null,
            subjectName: `upstream_event.${name}`,
            detail: { overflow: false },
            sinceUnixSeconds: now - 300 - index * 60,
          })),
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
          diskAvailableBytes: (36 + (120 - i) / 60) * 1024 ** 3,
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
            succeeded: 5,
            cancelled: 2,
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
          succeeded: 7 + i * 2,
          failed: 1,
          cancelled: 2,
          failures: { rate_limited: 1 },
          metrics: { ...metrics, images: i === 0 ? null : String(i + 2) },
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
  await expect(page.getByRole("heading", { name: "进行中请求" })).toBeVisible();
  await expect(
    page.getByRole("img", { name: /^今日已准入近 7 天/ }),
  ).toBeVisible();
  const cards = page.getByLabel("在途请求卡片").locator(":scope > *");
  await expect(cards).toHaveCount(5);
  const expectUniformGaps = async () => {
    const gaps = await page
      .getByLabel("关键指标", { exact: true })
      .evaluate((kpis) => {
        const main = kpis.parentElement!;
        const layout = main.parentElement!;
        const sidebar = layout.querySelector("aside")!;
        const requestGrid = layout.querySelector(
          '[aria-label="在途请求卡片"]',
        )!;
        return [kpis, main, layout, sidebar, requestGrid].map((element) => {
          const { rowGap, columnGap } = getComputedStyle(element);
          return [rowGap, columnGap];
        });
      });
    expect(gaps).toEqual(Array.from({ length: 5 }, () => ["16px", "16px"]));
  };
  await expect(page.getByText("今日运营概览", { exact: true })).toHaveCount(0);
  await expectUniformGaps();
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
    page.getByRole("img", {
      name: "生图张数近 7 天：不可用、3、4、5、6、7、8",
    }),
  ).toBeVisible();
  await expect(page.getByText("估算费用", { exact: true })).toHaveCount(0);
  await expect(page.getByText("5.0%", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "合成工作站 失败率 16.7%" }),
  ).toContainText("16.7%");

  const requestTrend = page.getByRole("img", { name: /今日已准入近 7 天/ });
  await requestTrend.hover();
  const trendTooltip = page.getByRole("tooltip");
  await expect(trendTooltip.getByText("16", { exact: true })).toBeVisible();
  await expect(trendTooltip).toContainText(
    new Intl.DateTimeFormat("zh-CN", {
      month: "long",
      day: "numeric",
      timeZone: "UTC",
    }).format((today - 3 * 86400) * 1000),
  );
  const sidebar = page.getByRole("complementary", {
    name: "订阅额度与系统状态",
  });
  await expect(
    sidebar.getByRole("heading", { name: "请求输出速率" }),
  ).toBeVisible();
  await expect(sidebar.getByText("暂无速率数据")).toBeVisible();

  await expect(
    page.getByRole("img", { name: "CodexOne 内存占用最近一小时趋势" }),
  ).toBeVisible();
  const cpuGauge = page.getByRole("group", { name: "CPU 使用率" });
  await expect(cpuGauge.getByText("27%", { exact: true })).toBeVisible();
  await expect(cpuGauge.locator("circle[pathLength]")).toHaveAttribute(
    "stroke-dasharray",
    "27 100",
  );
  const memoryGauge = page.getByRole("group", { name: "可用内存" });
  await expect(memoryGauge.getByText("5.3 / 8.0 GiB")).toBeVisible();
  await expect(page.getByText("窗口为上游观测，不是 Key 余额")).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "合成工作站 失败率 16.7%" }),
  ).toHaveAttribute(
    "href",
    /key=synthetic-key&start=[^&]+&end=[^&]+&outcome=failed/,
  );
  await expect(
    page.getByRole("img", { name: "CPU 使用率最近一小时趋势" }),
  ).toBeVisible();
  await expect(
    page.getByRole("img", { name: "可用内存最近一小时趋势" }),
  ).toBeVisible();
  await expect(page.getByRole("group", { name: "数据盘可用" })).toContainText(
    "36%",
  );
  await expect(
    page.getByRole("img", { name: "数据盘可用最近一小时趋势" }),
  ).toBeVisible();
  await expect(sidebar.getByText("最近一小时", { exact: true })).toHaveCount(0);
  for (const name of [
    "CPU 使用率",
    "可用内存",
    "数据盘可用",
    "CodexOne 内存占用",
  ]) {
    const plot = page.getByRole("img", { name: `${name}最近一小时趋势` });
    const captions = plot.locator("xpath=../preceding-sibling::div");
    await expect(captions).toHaveCSS("justify-content", "space-between");
    await expect(captions.getByText(name, { exact: true })).toHaveCSS(
      "text-align",
      "start",
    );
    const readout = captions.locator("p").last();
    await expect(readout).toHaveCSS("text-align", "end");
    const [text, graph] = await Promise.all([
      readout.boundingBox(),
      plot.boundingBox(),
    ]);
    expect(
      Math.abs(text!.x + text!.width - graph!.x - graph!.width),
    ).toBeLessThan(1);
  }
  const shortWindow = await page
    .getByRole("progressbar", { name: "5 小时额度已用比例" })
    .boundingBox();
  const longWindow = await page
    .getByRole("progressbar", { name: "每周额度已用比例" })
    .boundingBox();
  expect(longWindow!.y).toBeGreaterThan(shortWindow!.y);
  await expect(page.getByLabel("概览连接状态")).toBeHidden();
  await expect(page.getByText("各源更新时间", { exact: true })).toBeHidden();
  await expect(page.getByRole("img", { name: "参考进度 60.0%" })).toBeVisible();
  await expect(page.getByRole("img", { name: "参考进度 57.1%" })).toBeVisible();
  const protocol = sidebar.getByRole("region", { name: "协议观测" });
  const resources = sidebar.getByRole("heading", { name: "服务器运行资源" });
  await expect(protocol.getByRole("heading")).toHaveText("协议观测");
  expect((await protocol.boundingBox())!.y).toBeGreaterThan(
    (await resources.boundingBox())!.y,
  );
  await expect(
    protocol.getByText("upstream_event.response.metadata"),
  ).toBeVisible();
  await expect(
    protocol.getByText("upstream_event.responsesapi.websocket_timing"),
  ).toBeVisible();
  await expect(protocol.getByText(/首次观测：/)).toHaveCount(3);
  await expect(
    protocol.getByText("upstream_event.synthetic.earlier"),
  ).toBeVisible();
  await expect(protocol.getByRole("button")).toHaveCount(0);
  await page.setViewportSize({ width: 1440, height: 1200 });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.setViewportSize({ width: 1440, height: 900 });
  const rejected = page.getByText("拒绝 6");
  await expect(rejected).toBeVisible();
  const viewport = page.viewportSize()!;
  await page.setViewportSize({ width: 390, height: 844 });
  await expectUniformGaps();
  expect(await firstRow()).toBe(2);
  await rejected.scrollIntoViewIfNeeded();
  await expect(rejected).toBeInViewport();
  await page.setViewportSize(viewport);
  await expect(page.getByText("hidden-key-identifier")).toHaveCount(0);
  await expect(page.getByText("运行诊断", { exact: true })).toHaveCount(0);
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
  await expectUniformGaps();
  await expectNoHorizontalOverflow(page);
  await page.evaluate(() => window.scrollTo(0, 0));
  inFlightCount = 0;
  await page.clock.runFor(15000);
  await expect(cards).toHaveCount(0);
  await expect(page.getByText("暂无进行中请求")).toBeVisible();
});
