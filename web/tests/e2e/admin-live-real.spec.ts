import {
  expect,
  test as base,
  type APIRequestContext,
  type Page,
} from "@playwright/test";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { expectNoHorizontalOverflow } from "./layout";

type Gateway = { admin: string; data: string };

const test = base.extend<{ gateway: Gateway }>({
  gateway: async ({}, runTest) => {
    const binary = resolve(
      process.env.CODEXONE_WEB_TEST_BINARY ??
        "../rust/gateway/target/release/codexone",
    );
    const child = spawn(
      "python3",
      [
        "scripts/verify_admin_live.py",
        "--binary",
        binary,
        "--serve",
        "--web",
        "web/dist",
      ],
      { cwd: resolve(".."), stdio: ["pipe", "pipe", "pipe"] },
    );
    const lines = createInterface({ input: child.stdout });
    let diagnostics = "";
    child.stderr.on("data", (chunk) => {
      diagnostics += chunk;
    });
    const stopped = new Promise<void>((resolve) =>
      child.once("close", () => resolve()),
    );
    try {
      const ports = await new Promise<{ admin: number; data: number }>(
        (resolve, reject) => {
          lines.once("line", (line) => {
            try {
              resolve(JSON.parse(line));
            } catch (error) {
              reject(error);
            }
          });
          child.once("error", reject);
          void stopped.then(() =>
            reject(new Error(`synthetic gateway exited: ${diagnostics}`)),
          );
        },
      );
      await runTest({
        admin: `http://127.0.0.1:${ports.admin}`,
        data: `http://127.0.0.1:${ports.data}`,
      });
    } finally {
      lines.close();
      child.stdin.end("\n");
      await stopped;
    }
  },
});

const connectionStatus = (page: Page) => page.getByLabel("概览连接状态");
const keySummary = (page: Page) =>
  page.getByRole("region", { name: "今日 Key 请求汇总" });

async function login(page: Page, admin: string) {
  await page.goto(admin);
  await page.getByRole("button", { name: "管理员登录" }).click();
  await page.getByLabel("用户名").fill("admin");
  await page
    .getByLabel("管理员凭证", { exact: true })
    .fill("synthetic-admin-credential-for-local-key-tests");
  await page.getByRole("button", { name: "登录管理台", exact: true }).click();
}

async function createKey(page: Page, principal: string, verifyCsrf = false) {
  return page.evaluate(
    async ({ principal, verifyCsrf }) => {
      const session = await fetch("/api/session");
      if (!session.ok)
        throw new Error(`Session request failed: ${session.status}`);
      const { csrf } = await session.json();
      const body = JSON.stringify({
        principal,
        models: ["synthetic-text"],
        limits: { tokens: 1000000, active: 4 },
      });
      if (verifyCsrf) {
        const denied = await fetch("/api/keys", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body,
        });
        if (denied.status !== 403)
          throw new Error(
            `Expected missing CSRF to be denied, got ${denied.status}`,
          );
      }
      const response = await fetch("/api/keys", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CodexOne-CSRF": csrf,
        },
        body,
      });
      if (response.status !== 201)
        throw new Error(`Key creation failed: ${response.status}`);
      return (await response.json()) as { key: { id: string }; secret: string };
    },
    { principal, verifyCsrf },
  );
}

async function completeRequest(
  request: APIRequestContext,
  data: string,
  secret: string,
) {
  const response = await request.post(`${data}/v1/responses`, {
    headers: { Authorization: `Bearer ${secret}` },
    data: { model: "synthetic-text", input: "synthetic", stream: false },
  });
  expect(response.status()).toBe(200);
}

test("real login and confirmed updates before and after a live disconnect @smoke", async ({
  page,
  gateway,
}) => {
  test.setTimeout(40000);
  expect((await page.request.get(`${gateway.admin}/api/keys`)).status()).toBe(
    401,
  );
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  // Keep the initial socket native and close it on demand after proving live delivery.
  await page.addInitScript(() => {
    const Original = WebSocket;
    window.WebSocket = class extends Original {
      constructor(url: string | URL, protocols?: string | string[]) {
        super(url, protocols);
        if (new URL(url, location.href).pathname === "/api/overview/live") {
          window.addEventListener(
            "test-drop-overview-socket",
            () => this.close(),
            { once: true },
          );
        }
      }
    };
  });

  await login(page, gateway.admin);
  await expect(connectionStatus(page)).toHaveAttribute(
    "data-live-mode",
    "live",
  );
  const principal = "synthetic-browser";
  const { key, secret } = await createKey(page, principal, true);
  const row = keySummary(page).getByRole("row").filter({ hasText: principal });
  await completeRequest(page.request, gateway.data, secret);
  await expect(row.getByTitle("输出 Token 3", { exact: true })).toBeVisible({
    timeout: 10000,
  });
  await expect(connectionStatus(page)).toHaveAttribute(
    "data-live-mode",
    "live",
  );

  // Route only reconnection attempts so polling stays active during the second request.
  await page.routeWebSocket("**/api/overview/live", (socket) =>
    socket.close({ code: 1013 }),
  );
  await page.evaluate(() =>
    window.dispatchEvent(new Event("test-drop-overview-socket")),
  );
  await expect(connectionStatus(page)).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  await Promise.all([
    page.waitForResponse(
      async (response) => {
        if (
          response.url() !==
            `${gateway.admin}/api/usage/keys?includeArchived=false` ||
          !response.ok()
        )
          return false;
        const report = (await response.json()) as {
          keys: { keyID: string; succeeded: number }[];
        };
        return report.keys.some(
          (entry) => entry.keyID === key.id && entry.succeeded === 2,
        );
      },
      { timeout: 25000 },
    ),
    completeRequest(page.request, gateway.data, secret),
  ]);
  await expect(row.getByTitle("输出 Token 6", { exact: true })).toBeVisible();
  await expect(connectionStatus(page)).toHaveAttribute(
    "data-live-mode",
    "polling",
  );
  expect(errors).toEqual([]);
});

for (const realtime of [true, false]) {
  test(`real local gateway ${realtime ? "live" : "HTTP fallback"} sustains visual updates @visual`, async ({
    page,
    context,
    gateway,
  }) => {
    test.setTimeout(120000);
    page.setDefaultTimeout(10000);
    const mode = realtime ? "live" : "polling";
    if (!realtime)
      await page.routeWebSocket("**/api/overview/live", (socket) =>
        socket.close({ code: 1013 }),
      );
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(() => {
      const presentation = { numericAnimations: 0, csp: [] as string[] };
      (
        window as unknown as { livePresentation: typeof presentation }
      ).livePresentation = presentation;
      document.addEventListener("securitypolicyviolation", (event) => {
        if (presentation.csp.length < 16)
          presentation.csp.push(event.violatedDirective);
      });
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (
        ...args: Parameters<Element["animate"]>
      ) {
        if (this.matches("[data-digit]")) presentation.numericAnimations++;
        return animate.apply(this, args);
      };
      const closes: number[] = [];
      (window as unknown as { liveCloses: number[] }).liveCloses = closes;
      const Original = WebSocket;
      window.WebSocket = class extends Original {
        constructor(url: string | URL, protocols?: string | string[]) {
          super(url, protocols);
          this.addEventListener("close", (event) => {
            if (closes.length < 32) closes.push(event.code);
          });
        }
      };
    });
    await login(page, gateway.admin);
    await expect(connectionStatus(page)).toHaveAttribute(
      "data-live-mode",
      mode,
    );
    // Let the next sample or fallback poll settle if the first readers contend.
    await expect(
      keySummary(page).getByRole("link", { name: "p", exact: true }),
    ).toBeVisible({ timeout: 20000 });
    await page.waitForTimeout(2200);
    await page.setViewportSize({ width: 1440, height: 900 });
    await expectNoHorizontalOverflow(page);
    const { secret } = await createKey(page, "synthetic-browser");
    const start = Date.now();
    await completeRequest(context.request, gateway.data, secret);
    await expect(
      keySummary(page).getByText("synthetic-browser", { exact: true }),
    ).toBeVisible({ timeout: 20000 });
    await expect(page.getByText("最近结束 · 成功")).toHaveCount(0);
    const latency = Date.now() - start;
    console.log(
      `MEASURE ${realtime ? "live" : "polling"} request-start-to-browser-dom-ms=${latency} (upper bound for commit-to-browser)`,
    );
    const artifacts = "../artifacts/admin-live";
    await mkdir(artifacts, { recursive: true });
    await page.screenshot({
      path: `${artifacts}/real-${realtime ? "live" : "polling"}-wide.png`,
      fullPage: true,
    });
    await page.waitForTimeout(2200);
    await expect(connectionStatus(page)).toHaveAttribute(
      "data-live-mode",
      mode,
    );
    await page.evaluate(() => {
      const metrics = {
        cls: 0,
        longTasks: 0,
        maxTask: 0,
        shifts: [] as unknown[],
      };
      (window as unknown as { liveMetrics: typeof metrics }).liveMetrics =
        metrics;
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          const shift = entry as PerformanceEntry & {
            value: number;
            hadRecentInput: boolean;
          };
          if (!shift.hadRecentInput) {
            metrics.cls += shift.value;
            if (metrics.shifts.length < 16)
              metrics.shifts.push({
                value: shift.value,
                sources: (
                  entry as unknown as {
                    sources: {
                      node: Element;
                      previousRect: DOMRectReadOnly;
                      currentRect: DOMRectReadOnly;
                    }[];
                  }
                ).sources.map((source) => ({
                  tag: source.node?.tagName,
                  cls: source.node?.className,
                  previous: source.previousRect.toJSON(),
                  current: source.currentRect.toJSON(),
                })),
              });
          }
        }
      }).observe({ type: "layout-shift", buffered: false });
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          metrics.longTasks += 1;
          metrics.maxTask = Math.max(metrics.maxTask, entry.duration);
        }
      }).observe({ type: "longtask", buffered: false });
    });
    const stormUntil =
      Date.now() + Number(globalThis.process.env.ADMIN_LIVE_STORM_MS ?? 60000);
    let count = 0;
    while (Date.now() < stormUntil) {
      await completeRequest(context.request, gateway.data, secret);
      count += 1;
      await page.waitForTimeout(200);
    }
    await page.waitForTimeout(400);
    const metrics = await page.evaluate(
      () =>
        (
          window as unknown as {
            liveMetrics: { cls: number; longTasks: number; maxTask: number };
          }
        ).liveMetrics,
    );
    console.log(
      "FAILURE",
      await page.getByLabel("概览连接状态").getAttribute("data-live-failure"),
      await page.evaluate(
        () => (window as unknown as { liveCloses: number[] }).liveCloses,
      ),
    );
    console.log("SHIFTS", JSON.stringify(metrics));
    console.log(
      `MEASURE 60s changes=${count} cls=${metrics.cls} longTasks=${metrics.longTasks} maxTaskMs=${metrics.maxTask}`,
    );
    expect(metrics.cls).toBe(0);
    const presentation = await page.evaluate(() => {
      const digits = [
        ...document.querySelectorAll<HTMLElement>("[data-digit]"),
      ];
      return {
        ...(
          window as unknown as {
            livePresentation: { numericAnimations: number; csp: string[] };
          }
        ).livePresentation,
        renderedDigits: digits.length,
        digitsMatch: digits.every(
          (digit) =>
            getComputedStyle(digit, "::after").content ===
            JSON.stringify(digit.dataset.current),
        ),
        inlineStyles: document.querySelectorAll(
          "[data-continuous-value] [style]",
        ).length,
      };
    });
    console.log("MEASURE numeric-presentation", JSON.stringify(presentation));
    expect(presentation.numericAnimations).toBeGreaterThan(0);
    expect(presentation.renderedDigits).toBeGreaterThan(0);
    expect(presentation.digitsMatch).toBe(true);
    expect(presentation.inlineStyles).toBe(0);
    expect(presentation.csp).toEqual([]);
    await expect(page.getByLabel("概览连接状态")).toHaveAttribute(
      "data-live-mode",
      mode,
    );
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.setViewportSize({ width: 390, height: 844 });
    console.log(
      "NARROW",
      await page.evaluate(() => ({
        width: document.documentElement.scrollWidth,
        offenders: [...document.querySelectorAll("body *")]
          .filter((el) => el.getBoundingClientRect().right > innerWidth + 1)
          .slice(0, 8)
          .map((el) => ({
            tag: el.tagName,
            cls: el.className,
            text: el.textContent?.slice(0, 32),
          })),
      })),
    );
    await expectNoHorizontalOverflow(page);
    await page.screenshot({
      path: `${artifacts}/real-${realtime ? "live" : "polling"}-narrow-reduced.png`,
      fullPage: true,
    });
    await page.waitForTimeout(450);
    expect(
      await page.evaluate(
        () =>
          document
            .getAnimations()
            .filter((animation) => animation.playState === "running").length,
      ),
    ).toBe(0);
    if (realtime) {
      await page
        .getByRole("link", { name: "查看用量与诊断", exact: true })
        .click();
      const charts = ["请求趋势", "Key 用量占比"].map((name) =>
        page.getByRole("region", { name, exact: true }),
      );
      for (const chart of charts)
        await expect(chart).toHaveCSS("padding", "12px");
      await page.setViewportSize({ width: 1440, height: 900 });
      for (const chart of charts)
        await expect(chart).toHaveCSS("padding", "16px");
      const violations = await page.evaluate(
        () =>
          (window as unknown as { livePresentation: { csp: string[] } })
            .livePresentation.csp,
      );
      expect(violations).toEqual([]);
    }
    expect(errors).toEqual([]);
  });
}
