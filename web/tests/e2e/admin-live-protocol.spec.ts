import { expect, test } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import type { Page, WebSocketRoute } from "@playwright/test";
import { keySummary } from "../../src/features/system-status/round2-api";

test("live metadata preserves content, skipped sequences fall back, and revocation clears private data", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
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
  await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
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
  const originalSocket = socket;
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 3,
      kind: "update",
      sections: {
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
  await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).getByRole("status"),
  ).toContainText("保留上次成功快照");
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
  ).toHaveText(previous);
  await page.locator("summary").filter({ hasText: "概览读取失败" }).click();
  await expect(page.getByText(/今日 Key 汇总 · .* · 已陈旧/)).toBeVisible();
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 5,
      kind: "update",
      sections: {},
    }),
  );
  await expect(page.getByText("轮询模式（15 秒）· 活动观察中断")).toBeVisible();
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
  ).toHaveText(previous);
  // The HTTP check decides whether a disconnected socket means logout.
  await expect.poll(() => socket !== originalSocket).toBe(true);
  state.anonymous = true;
  socket!.close({ code: 1008 });
  await expect(page.getByRole("heading", { name: "今日运营概览" })).toHaveCount(
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
  await page.getByText("运行诊断", { exact: true }).click();
  await expect(page.getByText("已就绪", { exact: true })).toBeVisible();
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
    await expect(
      page.getByText("服务状态已陈旧，保留上次成功快照。"),
    ).toBeVisible();
    await expect(
      page.getByText("当前可用性无法确认", { exact: true }),
    ).toBeVisible();
  } finally {
    release?.();
  }
});

test("a new server epoch retires the pinned request instead of carrying it across restart", async ({
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
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-before-restart",
      sequence: 1,
      kind: "snapshot",
      sections,
    }),
  );
  const watch = page.getByRole("region", { name: "请求关注" });
  await watch.getByRole("button", { name: "关注下一次请求" }).click();
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-before-restart",
      sequence: 2,
      kind: "update",
      sections: {
        inFlight: {
          ...sections.inFlight,
          version: 2,
          data: {
            rows: [
              {
                id: "synthetic-retired-request",
                keyID: "synthetic-key",
                mode: "http",
                accountID: null,
                hasFirstEvent: false,
              },
            ],
            recentlyFinished: [],
            clients: [],
            overflow: 0,
          },
        },
      },
    }),
  );
  await expect(watch.getByText("synthetic-retired-request")).toBeVisible();
  const previous = socket;
  socket!.close({ code: 1013 });
  await expect(watch.getByText("观察中断，结果尚未确认")).toBeVisible();
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
  await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
  await expect(watch.getByText("synthetic-retired-request")).toHaveCount(0);
  await expect(
    watch.getByRole("button", { name: "关注下一次请求" }),
  ).toBeEnabled();
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
      ...sections,
      keys: {
        ...sections.keys,
        data: null,
        lastSuccessAt: null,
        freshness: "unavailable",
        code: "source_unavailable",
      },
    };
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-null",
        sequence: 1,
        kind: "snapshot",
        sections: unavailable,
      }),
    );
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
    await expect(
      page.getByText("今日 Key 汇总读取失败。请重试。"),
    ).toBeVisible();
    await expect(page.getByText("今日暂无活跃 Key。")).toHaveCount(0);
    socket!.send(
      JSON.stringify({
        protocol: 1,
        epoch: "synthetic-null",
        sequence: 2,
        kind: "update",
        sections: { keys: sections.keys },
      }),
    );
    await expect(page.getByText("今日 Key 汇总读取失败。请重试。")).toHaveCount(
      0,
    );
    await expect(
      page.getByRole("region", { name: "今日 Key 请求汇总" }).locator("table"),
    ).toBeVisible();
  } finally {
    release?.();
  }
});

test("successful HTTP fallback advances source freshness beyond 45 seconds", async ({
  page,
}) => {
  await page.clock.install();
  await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  let reject = false;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    if (reject) route.close({ code: 1013 });
    else socket = route;
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
  await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
  reject = true;
  socket!.close({ code: 1013 });
  await expect(page.getByText("轮询模式（15 秒）· 活动观察中断")).toBeVisible();
  await page.clock.fastForward(46000);
  await page.getByRole("button", { name: "刷新请求概览" }).click();
  await expect(page.getByText("轮询模式（15 秒）· 活动观察中断")).toBeVisible();
  await expect(
    page.locator("summary").filter({ hasText: "各源更新时间" }),
  ).toHaveText("各源更新时间");
  await page.getByText("各源更新时间", { exact: true }).click();
  await expect(page.getByText(/存储与备份 · .* · 已更新/)).toBeVisible();
  await expect(page.getByText(/今日 Key 汇总 · .* · 已更新/)).toBeVisible();
});

for (const width of [1440, 390])
  test(`watch next request retains outcome and provides honest diagnostics at ${width}px`, async ({
    page,
  }, testInfo) => {
    await reviewFixture(page);
    let socket: WebSocketRoute | undefined;
    await page.routeWebSocket("**/api/overview/live", (route) => {
      socket = route;
    });
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    await expect.poll(() => !!socket).toBe(true);
    const sections = await initialSections(page);
    const send = (
      sequence: number,
      inFlight: unknown,
      epoch = "synthetic-watch",
    ) =>
      socket!.send(
        JSON.stringify({
          protocol: 1,
          epoch,
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
    const watch = page.getByRole("region", { name: "请求关注", exact: true });
    await expect(
      watch.getByRole("button", { name: "关注下一次请求" }),
    ).toBeEnabled();
    const watchedKey = keySummary.parse(sections.keys.data).keys[0].keyID;
    await watch.getByLabel("关注范围").selectOption(watchedKey);
    await watch.getByRole("button", { name: "关注下一次请求" }).click();
    const row = {
      id: "synthetic-watched-request",
      keyID: watchedKey,
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
    send(2, {
      ...data,
      rows: [
        { ...row, id: "synthetic-other-request", keyID: "synthetic-other-key" },
      ],
    });
    await expect(watch.getByText(/正在等待新请求/)).toBeVisible();
    await expect(watch.getByText("synthetic-other-request")).toHaveCount(0);
    send(3, data);
    await expect(watch.getByText(row.id)).toBeVisible();
    await expect(watch.getByText("等待首个上游事件")).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "持续连接", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: "-unnamed", exact: true }),
    ).toBeVisible();
    send(4, {
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
    await expect(watch.getByText("成功返回")).toBeVisible();
    send(5, { ...data, rows: [], recentlyFinished: [] });
    await expect(watch.getByText(row.id)).toBeVisible();
    await expect(
      watch.getByRole("link", { name: "按 Key 查看用量与诊断" }),
    ).toHaveAttribute(
      "href",
      `#/usage?key=${encodeURIComponent(watchedKey)}&range=24h`,
    );
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    await watch.scrollIntoViewIfNeeded();
    await page.screenshot({
      path: testInfo.outputPath(`request-watch-${width}.png`),
    });
    await page.getByRole("switch", { name: "实时观察" }).uncheck();
    await expect(watch.getByText("成功返回")).toBeVisible();
  });
