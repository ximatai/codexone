import { expect, test } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";
import { expectNoHorizontalOverflow } from "./layout";

test("real local gateway streams committed short requests and supports pause, reconnect and narrow reduced motion", async ({
  page,
  context,
}) => {
  test.setTimeout(120000);
  page.setDefaultTimeout(10000);
  const binary = resolve("../.build/debug/codexone");
  const process: ChildProcess = spawn(
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
  const lines = createInterface({ input: process.stdout! });
  let diagnostics = "";
  process.stderr!.on("data", (chunk) => {
    diagnostics += chunk;
  });
  try {
    const ports = await new Promise<{ admin: number; data: number }>(
      (resolve, reject) => {
        lines.once("line", (line) => resolve(JSON.parse(line)));
        process.once("exit", () =>
          reject(new Error(`synthetic gateway exited: ${diagnostics}`)),
        );
      },
    );
    const origin = `http://127.0.0.1:${ports.admin}`;
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await context.addCookies([
      { name: "synthetic", value: "unused", url: origin },
    ]);
    // Same-origin production asset/CSP and actual cookie/CSRF: no intercepted API or socket.
    await page.addInitScript(() => {
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
    await page.goto(origin);
    await page.getByRole("button", { name: "管理员登录" }).click();
    await page.getByLabel("用户名").fill("admin");
    await page
      .getByLabel("管理员凭证", { exact: true })
      .fill("synthetic-admin-credential-for-local-key-tests");
    await page.getByRole("button", { name: "登录管理台", exact: true }).click();
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
    await page.setViewportSize({ width: 1440, height: 900 });
    await expectNoHorizontalOverflow(page);
    const session = await page.evaluate(async () =>
      (await fetch("/api/session")).json(),
    );
    const created = await page.evaluate(
      async (csrf) =>
        (
          await fetch("/api/keys", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CodexOne-CSRF": csrf,
            },
            body: JSON.stringify({
              principal: "synthetic-browser",
              models: ["synthetic-text"],
              limits: { tokens: 1000000, active: 4 },
            }),
          })
        ).json(),
      session.csrf,
    );
    const start = Date.now();
    const response = await context.request.post(
      `http://127.0.0.1:${ports.data}/v1/responses`,
      {
        headers: { Authorization: `Bearer ${created.secret}` },
        data: { model: "synthetic-text", input: "synthetic", stream: false },
      },
    );
    expect(response.status()).toBe(200);
    await expect(page.getByText("最近结束 · 成功").first()).toBeVisible();
    const latency = Date.now() - start;
    console.log(
      `MEASURE request-start-to-browser-dom-ms=${latency} (upper bound for commit-to-browser)`,
    );
    const artifacts = "../artifacts/admin-live";
    await mkdir(artifacts, { recursive: true });
    await page.screenshot({
      path: `${artifacts}/real-wide.png`,
      fullPage: true,
    });
    await page.getByLabel("实时观察").uncheck();
    await expect(page.getByText("观察已暂停", { exact: true })).toBeVisible();
    await page.getByLabel("自动刷新（15 秒）").check();
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "刷新请求概览" }).click();
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
    await page.waitForTimeout(2200);
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
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
      const response = await context.request.post(
        `http://127.0.0.1:${ports.data}/v1/responses`,
        {
          headers: { Authorization: `Bearer ${created.secret}` },
          data: { model: "synthetic-text", input: "synthetic", stream: false },
        },
      );
      expect(response.status()).toBe(200);
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
    await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
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
      path: `${artifacts}/real-narrow-reduced.png`,
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
    expect(errors).toEqual([]);
  } finally {
    lines.close();
    process.stdin?.end("\n");
    await new Promise<void>((resolve) => {
      if (process.exitCode !== null) resolve();
      else process.once("exit", () => resolve());
    });
  }
});
