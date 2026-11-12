import { expect, test } from "./fixtures";
import { keySummary } from "../../src/features/system-status/round2-api";
import { reviewFixture } from "./ui-review-fixture";
import type { Page, WebSocketRoute } from "@playwright/test";

test("live metadata preserves content, invalid sections fall back, and revocation clears private data", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const sections = await initialSections(page);
  const now = Date.now() / 1000;
  const snapshot = {
    protocol: 1,
    epoch: "synthetic-epoch",
    sequence: 1,
    kind: "snapshot",
    sections,
  };
  socket!.send(JSON.stringify(snapshot));
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  const protocol = page.getByRole("region", { name: "协议观测" });
  await expect(protocol).toHaveCount(0);
  const previous =
    (await page
      .getByRole("region", { name: "今日 Key 请求汇总" })
      .locator("table")
      .textContent()) ?? "";
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 2,
      kind: "update",
      sections: {
        attention: {
          ...sections.attention,
          version: 2,
          data: {
            generatedAtUnixSeconds: now,
            items: [
              {
                kind: "client_protocol_extension",
                severity: "warning",
                subjectType: "protocol",
                subjectID: null,
                subjectName: "upstream_event.synthetic.notice",
                sinceUnixSeconds: now,
                detail: {},
              },
            ],
          },
        },
        keys: {
          version: 1,
          sampledAtUnixSeconds: now + 1,
          lastSuccessAt: now + 1,
          freshness: "fresh",
          code: null,
        },
      },
    }),
  );
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
  ).toHaveText(previous);
  await expect(
    protocol.getByText("upstream_event.synthetic.notice"),
  ).toBeVisible();
  await expect(protocol.getByRole("heading")).toHaveText("协议观测");
  await expect(page.getByRole("region", { name: "运行提醒" })).toHaveCount(0);
  const originalSocket = socket;
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 3,
      kind: "update",
      sections: {
        attention: { ...sections.attention, version: 3 },
        keys: {
          version: 1,
          sampledAtUnixSeconds: now + 2,
          lastSuccessAt: now + 1,
          freshness: "unavailable",
          code: "source_unavailable",
        },
      },
    }),
  );
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).getByRole("status"),
  ).toContainText("上次更新");
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
  ).toHaveText(previous);
  await expect(protocol).toHaveCount(0);
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 4,
      kind: "update",
      sections: {
        keys: {
          ...sections.keys,
          version: 2,
          data: { ...keySummary.parse(sections.keys.data), keys: [] },
        },
        inFlight: {
          ...sections.inFlight,
          version: 2,
          data: {
            rows: [],
            clients: [],
            overflow: 0,
            requestOutputRateMediansByDay: [],
          },
        },
      },
    }),
  );
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
  ).toHaveText(previous);
  // The HTTP check decides whether a disconnected socket means logout.
  await expect.poll(() => socket !== originalSocket).toBe(true);
  state.anonymous = true;
  socket!.close({ code: 1008 });
  await expect(page.getByRole("heading", { name: "进行中请求" })).toHaveCount(
    0,
  );
  await expect(page.getByRole("button", { name: "管理员登录" })).toBeVisible();
});

async function initialSections(page: Page) {
  const data = await page.evaluate(async () => {
    const paths: Record<string, string> = {
      system: "/api/system",
      inFlight: "/api/usage/in-flight",
      daily: "/api/usage/daily?days=7",
      keys: "/api/usage/keys?includeArchived=false",
      accounts: "/api/accounts",
      storage: "/api/runtime/storage",
      attention: "/api/attention",
      headroom: "/api/usage/headroom",
    };
    return Object.fromEntries(
      await Promise.all(
        Object.entries(paths).map(async ([name, path]) => [
          name,
          await (await fetch(path)).json(),
        ]),
      ),
    );
  });
  data.inFlight = {
    ...data.inFlight,
    recentlyFinished: [],
    clients: [],
    overflow: 0,
  };
  const now = Date.now() / 1000;
  const sections = Object.fromEntries(
    Object.entries(data).map(([name, value]) => [
      name,
      {
        version: 1,
        sampledAtUnixSeconds: now,
        lastSuccessAt: now,
        freshness: "fresh",
        code: null,
        data: value,
      },
    ]),
  );
  return sections;
}

test("HTTP pending over an old snapshot marks the module and availability summary stale", async ({
  page,
}) => {
  await page.clock.install();
  await reviewFixture(page);
  await page.routeWebSocket("**/api/overview/live", (route) =>
    route.close({ code: 1013 }),
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "进行中请求" })).toBeVisible();
  let release: (() => void) | undefined;
  await page.route("**/api/system", async (route) => {
    await new Promise<void>((resolve) => {
      release = resolve;
    });
    await route
      .fulfill({ json: { service: "codexone", ready: true, checks: [] } })
      .catch(() => {});
  });
  try {
    await page.clock.fastForward(46000);
    await expect.poll(() => !!release).toBe(true);
    await expect(page.getByRole("region", { name: "运行提醒" })).toHaveCount(0);
  } finally {
    release?.();
  }
});

test("a new server epoch replaces the in-flight snapshot", async ({ page }) => {
  await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const sections = await initialSections(page);
  const day = Math.floor(Date.now() / 86400000) * 86400;
  sections.daily.data = {
    timezone: "UTC",
    days: 1,
    buckets: [
      {
        atUnixSeconds: day,
        requests: 1,
        succeeded: 1,
        failed: 0,
        cancelled: 0,
        failures: {},
        metrics: {
          inputTokens: "2",
          cachedTokens: "0",
          outputTokens: "42",
          images: "0",
          estimatedMicros: "0",
        },
      },
    ],
  };
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-before-restart",
      sequence: 1,
      kind: "snapshot",
      sections: {
        ...sections,
        inFlight: {
          ...sections.inFlight,
          data: {
            rows: [],
            clients: [],
            overflow: 0,
            settledOutputTokensPerSecond: 999,
            settledOutputRatesByDay: { [day]: 999 },
          },
        },
      },
    }),
  );
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  await expect(
    page.getByRole("heading", { name: "进行中请求", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("暂无速率数据")).toBeVisible();
  const sendHourlyRate = (sequence: number, median: number, count: number) => {
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-before-restart",
        sequence,
        kind: "update",
        sections: {
          inFlight: {
            ...sections.inFlight,
            version: sequence,
            data: {
              rows: [
                {
                  id: "synthetic-retired-request",
                  model: "synthetic-retired-model",
                  keyID: "synthetic-key",
                  mode: "http",
                  accountID: null,
                  hasFirstEvent: false,
                  elapsedSeconds: 3,
                },
              ],
              recentlyFinished: [],
              clients: [],
              overflow: 0,
              recentRequestOutputRateMedian: 42.5,
              requestOutputRateByHour: {
                endUnixSeconds: day,
                offsetMinutes: 480,
                points: {
                  [day - 3 * 3600]: { median: 20, count: 2 },
                  [day - 2 * 3600]: { median: 30, count: 3 },
                  [day]: { median, count },
                },
              },
            },
          },
        },
      }),
    );
  };
  sendHourlyRate(2, 42.5, 5);
  await expect(
    page.getByLabel("在途请求卡片").getByText("synthetic-retired-model"),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "进行中请求 · 43 Token/s" }),
  ).toBeVisible();
  const trend = page.getByRole("img", { name: /^请求输出速率近 7 天/ });
  const resources = page.getByRole("heading", { name: "服务器运行资源" });
  await expect(trend).toBeVisible();
  await expect(trend).toHaveAccessibleName(/最近有样本的小时 43 Token\/s/);
  const dots = trend.locator("circle.recharts-dot");
  await expect(dots).toHaveCount(1);
  await dots.hover();
  await expect(page.getByRole("tooltip")).toContainText(
    "43 Token/s · 5 笔样本",
  );
  await expect(page.getByRole("tooltip")).toContainText("08:00");
  await page.getByRole("heading", { name: "请求输出速率" }).hover();
  const readout = page
    .locator('[title="最近有样本的小时"]')
    .locator("[data-continuous-value]");
  await expect(readout).toHaveText("最近 43 Token/s");
  const readoutBox = await readout.boundingBox();
  for (const [sequence, median, label] of [
    [3, 1234, "1,234 Token/s"],
    [4, 0, "0 Token/s"],
  ] as const) {
    sendHourlyRate(sequence, median, 6);
    await expect(readout).toHaveText(`最近 ${label}`);
    await expect(trend).toHaveAccessibleName(
      `请求输出速率近 7 天：最近有样本的小时 ${label}`,
    );
    expect(await readout.boundingBox()).toEqual(readoutBox);
  }
  const originalViewport = page.viewportSize()!;
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(trend).toBeVisible();
  const narrowTrend = await trend.boundingBox();
  expect(narrowTrend!.x + narrowTrend!.width).toBeLessThanOrEqual(390);
  await page.setViewportSize(originalViewport);
  const resourceTop = await resources.evaluate(
    (heading) => heading.getBoundingClientRect().top,
  );
  for (const [sequence, freshness, heading] of [
    [5, "stale", "进行中请求"],
    [6, "fresh", "进行中请求 · 43 Token/s"],
  ] as const) {
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-before-restart",
        sequence,
        kind: "update",
        sections: {
          inFlight: {
            version: 4,
            sampledAtUnixSeconds: sections.inFlight.sampledAtUnixSeconds,
            lastSuccessAt: sections.inFlight.lastSuccessAt,
            freshness,
            code: freshness === "stale" ? "source_unavailable" : null,
          },
        },
      }),
    );
    await expect(
      page.getByRole("heading", { name: heading, exact: true }),
    ).toBeVisible();
    await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
      "data-live-mode",
      "live",
    );
    if (freshness === "stale") {
      await expect(page.getByText("暂无速率数据")).toBeVisible();
      await expect(trend).toHaveCount(0);
    } else {
      await expect(trend).toBeVisible();
    }
    expect(
      await resources.evaluate(
        (element) => element.getBoundingClientRect().top,
      ),
    ).toBe(resourceTop);
  }
  let releaseFlight: (() => void) | undefined;
  await page.route("**/api/usage/in-flight", async (route) => {
    await new Promise<void>((resolve) => {
      releaseFlight = resolve;
    });
    await route.fulfill({ json: { rows: [] } }).catch(() => {});
  });
  const previous = socket;
  try {
    socket!.close({ code: 1013 });
    await expect.poll(() => !!releaseFlight, { timeout: 5000 }).toBe(true);
    await expect(page.getByText("正在核对请求，显示上次状态。")).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "进行中请求", exact: true }),
    ).toBeVisible();
    const cards = page.getByLabel("在途请求卡片");
    await expect(cards.getByText("3 秒", { exact: true })).toBeVisible();
    releaseFlight?.();
    await expect(cards).toHaveCount(0);
    await expect(page.getByText("正在核对请求，显示上次状态。")).toHaveCount(0);
  } finally {
    releaseFlight?.();
  }
  await expect.poll(() => socket !== previous).toBe(true);
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-after-restart",
      sequence: 1,
      kind: "snapshot",
      sections,
    }),
  );
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  await expect(page.getByText("synthetic-retired-model")).toHaveCount(0);
});

test("initial unavailable snapshot ends cancelled HTTP loading; source recovers without fake zero", async ({
  page,
}) => {
  await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const sections = await initialSections(page);
  const original = socket;
  let release: (() => void) | undefined;
  await page.route("**/api/usage/keys?*", async (route) => {
    await new Promise<void>((resolve) => {
      release = resolve;
    });
    await route.fulfill({ json: sections.keys.data }).catch(() => {});
  });
  try {
    await page.reload();
    await expect.poll(() => !!release && socket !== original).toBe(true);
    const unavailable = {
      version: 1,
      sampledAtUnixSeconds: sections.keys.sampledAtUnixSeconds,
      data: null,
      lastSuccessAt: null,
      freshness: "unavailable",
      code: "source_unavailable",
    };
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-null",
        sequence: 1,
        kind: "snapshot",
        sections: { ...sections, keys: unavailable, attention: unavailable },
      }),
    );
    await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
      "data-live-mode",
      "live",
    );
    await expect(page.getByText("Key 汇总读取失败")).toBeVisible();
    await expect(page.getByLabel("概览连接状态")).toContainText("运行提醒");
    await expect(page.getByRole("region", { name: "运行提醒" })).toHaveCount(0);
    await expect(page.getByText("暂无活跃 Key")).toHaveCount(0);
    const failedSocket = socket;
    failedSocket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-null",
        sequence: 2,
        kind: "update",
        sections: { storage: sections.storage },
      }),
    );
    await page.getByRole("button", { name: "重试", exact: true }).click();
    await expect.poll(() => socket !== failedSocket).toBe(true);
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-retry",
        sequence: 1,
        kind: "snapshot",
        sections,
      }),
    );
    await expect(page.getByText("Key 汇总读取失败")).toHaveCount(0);
    await expect(
      page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
    ).toBeVisible();
  } finally {
    release?.();
  }
});

test("push updates resources without HTTP polling and resumes after fallback", async ({
  page,
}) => {
  test.setTimeout(45_000);
  await page.clock.install();
  const state = await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  let reject = false;
  let reconnectSnapshot: string | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    if (reject) route.close({ code: 1013 });
    else {
      socket = route;
      if (reconnectSnapshot) route.send(reconnectSnapshot);
    }
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const sections = await initialSections(page);
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-fallback",
      sequence: 1,
      kind: "snapshot",
      sections,
    }),
  );
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  const overviewPaths = new Set([
    "/api/system",
    "/api/usage/in-flight",
    "/api/usage/daily",
    "/api/usage/keys",
    "/api/accounts",
    "/api/runtime/storage",
    "/api/attention",
    "/api/usage/headroom",
  ]);
  const overviewReads = () =>
    state.reads.filter(({ path }) => overviewPaths.has(path)).length;
  const initialReads = overviewReads();
  const loadValue = page
    .getByRole("group", { name: "CPU 使用率" })
    .getByText("0.00", { exact: true });
  await expect(loadValue).toHaveCount(0);
  const diskTrend = page.getByRole("img", { name: "数据盘可用最近一小时趋势" });
  await expect(diskTrend).toHaveCount(0);
  await page.clock.fastForward(16000);
  expect(overviewReads()).toBe(initialReads);
  const sampleTime = await page.evaluate(() => Math.floor(Date.now() / 1000));
  const resource = {
    ...sections.storage,
    version: 2,
    sampledAtUnixSeconds: sampleTime,
    lastSuccessAt: sampleTime,
    data: {
      pressure: "normal",
      admissionAllowed: true,
      optionalWorkAllowed: true,
      availableBytes: 40 * 1024 ** 3,
      volumeTotalBytes: 100 * 1024 ** 3,
      resources: [
        {
          unixSeconds: sampleTime - 30,
          hostCPUPercent: 10,
          diskAvailableBytes: 41 * 1024 ** 3,
          hostAvailableBytes: 4,
          hostTotalBytes: 8,
          processResidentBytes: 128 * 1024 ** 2,
        },
        {
          unixSeconds: sampleTime,
          hostCPUPercent: 25,
          diskAvailableBytes: 40 * 1024 ** 3,
          hostLoadAverage1m: 0,
          hostAvailableBytes: 6,
          hostTotalBytes: 8,
          processResidentBytes: 256 * 1024 ** 2,
        },
      ],
    },
  };
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-fallback",
      sequence: 2,
      kind: "update",
      sections: { storage: resource },
    }),
  );
  await expect(page.getByRole("group", { name: "CPU 使用率" })).toContainText(
    "25%",
  );
  await expect(loadValue).toBeVisible();
  await expect(page.getByRole("group", { name: "可用内存" })).toContainText(
    "75%",
  );
  await expect(page.getByRole("group", { name: "数据盘可用" })).toContainText(
    "40%",
  );
  await expect(
    page.getByRole("img", { name: "CodexOne 内存占用最近一小时趋势" }),
  ).toBeVisible();
  for (const [label, value] of [
    ["CPU 使用率", "25.0%"],
    ["可用内存", "0.0 MiB"],
    ["数据盘可用", "40.00 GiB"],
    ["CodexOne 内存占用", "256.0 MiB"],
  ]) {
    const chart = page.getByRole("img", { name: `${label}最近一小时趋势` });
    await expect(
      chart.locator("../..").getByText(value, { exact: true }),
    ).toBeVisible();
    const bounds = (await chart.boundingBox())!;
    await chart.hover({ position: { x: bounds.width - 1, y: 14 } });
    await expect(page.getByRole("tooltip")).toContainText(value);
  }
  await page.getByRole("heading", { name: "服务器运行资源" }).hover();
  await expect(page.getByRole("tooltip")).toHaveCount(0);
  expect(overviewReads()).toBe(initialReads);
  reject = true;
  socket!.close({ code: 1013 });
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  await page.clock.fastForward(46000);
  await expect.poll(overviewReads).toBeGreaterThan(initialReads);
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  await expect(page.getByText("各源更新时间", { exact: true })).toHaveCount(0);
  const previousSocket = socket;
  const resumed = await page.evaluate(() => Math.floor(Date.now() / 1000) + 61);
  const fresh = Object.fromEntries(
    Object.entries({ ...sections, storage: resource }).map(([name, source]) => [
      name,
      { ...source, lastSuccessAt: resumed, sampledAtUnixSeconds: resumed },
    ]),
  );
  reconnectSnapshot = JSON.stringify({
    protocol: 1,
    epoch: "synthetic-fallback",
    sequence: 1,
    kind: "snapshot",
    sections: fresh,
  });
  reject = false;
  await page.clock.fastForward(61000);
  await expect.poll(() => socket !== previousSocket).toBe(true);
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  const resumedReads = overviewReads();
  await page.clock.fastForward(16000);
  expect(overviewReads()).toBe(resumedReads);
});

test("live request cards leave the grid with reduced motion on a narrow screen", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.setViewportSize({ width: 390, height: 900 });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const sections = await initialSections(page);
  const send = (sequence: number, inFlight: unknown) =>
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-watch",
        sequence,
        kind: sequence === 1 ? "snapshot" : "update",
        sections:
          sequence === 1
            ? sections
            : {
                inFlight: {
                  ...sections.inFlight,
                  version: sequence,
                  data: inFlight,
                },
              },
      }),
    );
  send(1, null);
  const cards = page.getByLabel("在途请求卡片");
  await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  const row = {
    id: "synthetic-running-request",
    keyID: "synthetic-key",
    principal: "synthetic-tool",
    model: "synthetic-text",
    mode: "http",
    accountID: null,
    elapsedSeconds: 0,
    startedAtUnixSeconds: Math.floor(Date.now() / 1000),
    hasFirstEvent: false,
  };
  const data = {
    rows: [row],
    recentlyFinished: [],
    clients: [
      {
        keyID: "synthetic-unnamed",
        displayName: null,
        count: 1,
        connectedAtUnixSeconds: Math.floor(Date.now() / 1000),
      },
    ],
    overflow: 0,
  };
  send(2, data);
  await expect(cards.getByText("synthetic-text")).toBeVisible();
  await expect(cards.getByText("等待响应")).toBeVisible();
  // Older gateways can still send a retained completion. Only rows drive the cards.
  send(3, {
    ...data,
    rows: [],
    recentlyFinished: [
      {
        ...row,
        outcome: "succeeded",
        finishedAtUnixSeconds: Math.floor(Date.now() / 1000),
      },
    ],
  });
  await expect(cards).toHaveCount(0);
  await expect(page.getByText("暂无进行中请求")).toBeVisible();
});
