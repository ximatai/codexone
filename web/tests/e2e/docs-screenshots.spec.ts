import type { WebSocketRoute } from "@playwright/test";
import { initialSections } from "./overview-snapshot";
import { expectNoHorizontalOverflow } from "./layout";
import { mkdir } from "node:fs/promises";
import { expect, test } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { reportFixture } from "../../src/features/usage/usage.test-data";

// Documentation assets contain only generated fixtures; no live API or login.
test("render synthetic documentation screenshots", async ({ page }) => {
  const state = await reviewFixture(page);
  const now = Date.parse("2026-11-20T12:00:00Z") / 1000;
  await page.clock.setFixedTime(new Date(now * 1000));
  state.alerts = 0;
  state.keys.splice(4);
  state.keys.forEach((key, i) => {
    key.principal = ["workstation", "notebook", "codex-cli", "nightly-jobs"][i];
    key.expiresAtUnixSeconds = null;
    key.createdAtUnixSeconds = now - 86400;
    key.limits.tokens = 1000000;
  });
  state.accounts.splice(1);
  state.keys.forEach((key) => {
    key.enabled = true;
  });
  state.accounts[0].observability.quota.limits[0].primary.usedPercent = 36;
  state.accounts[0].displayName = "合成订阅账号";
  state.accounts[0].observability.quota.limits[0].primary.resetsAtUnixSeconds =
    now + 7200;
  const report = reportFixture();
  report.startUnixSeconds = Math.floor(now / 3600) * 3600 - 23 * 3600;
  report.endUnixSeconds = report.startUnixSeconds + 86400;
  report.totals = {
    ...report.totals,
    admitted: 24,
    complete: 24,
    unknown: 0,
    unavailable: 0,
    cancelled: 0,
    recordedRejections: 0,
    unresolvedExposureMicros: "0",
    metrics: {
      inputTokens: "12000",
      outputTokens: "2400",
      cachedTokens: "8000",
      images: "0",
      estimatedMicros: "42000",
    },
  };
  report.rows = Array.from({ length: 4 }, (_, i) => ({
    ...report.rows[0],
    id: `synthetic-request-${i}`,
    requestID: `synthetic-request-${i}`,
    keyID: state.keys[i].id,
    principal: state.keys[i].principal,
    firstEventMilliseconds: 800,
    totalMilliseconds: 6500,
    atUnixSeconds: now - i * 300,
    metrics: report.totals.metrics,
  }));
  report.buckets = report.buckets.map((bucket, i) => ({
    ...bucket,
    atUnixSeconds: report.startUnixSeconds + i * 3600,
    admitted: i % 3 === 0 ? 3 : 0,
    recordedRejections: 0,
    unresolved: 0,
  }));
  await page.route("**/api/attention", (route) =>
    route.fulfill({
      json: {
        generatedAtUnixSeconds: now,
        items: [
          {
            kind: "client_protocol_extension",
            severity: "warning",
            subjectType: "protocol",
            subjectID: null,
            subjectName: "upstream_event.synthetic.notice",
            detail: { overflow: false },
            sinceUnixSeconds: now - 300,
          },
        ],
      },
    }),
  );
  await page.route("**/api/usage?*", (route) =>
    route.fulfill({ json: { ...report, nextCursor: null } }),
  );
  await page.route("**/api/usage/daily?*", (route) =>
    route.fulfill({
      json: {
        timezone: "UTC",
        days: 7,
        buckets: Array.from({ length: 7 }, (_, i) => ({
          atUnixSeconds: Math.floor(now / 86400) * 86400 - (6 - i) * 86400,
          requests: 12 + i * 2,
          recordedRejections: 0,
          succeeded: 12 + i * 2,
          failed: 0,
          cancelled: 0,
          failures: {},
          metrics: report.totals.metrics,
        })),
      },
    }),
  );
  await page.route("**/api/usage/keys*", (route) =>
    route.fulfill({
      json: {
        timezone: "UTC",
        startUnixSeconds: Math.floor(now / 86400) * 86400,
        endUnixSeconds: (Math.floor(now / 86400) + 1) * 86400,
        keys: state.keys.map((key, i) => ({
          keyID: key.id,
          principal: key.principal,
          admitted: [8, 6, 6, 4][i],
          succeeded: [8, 6, 6, 4][i],
          cancelled: 0,
          inFlight: 0,
          failed: 0,
          pending: 0,
          tokens: String([6400, 4000, 2800, 1200][i]),
          tokenUsageIncomplete: false,
          inputTokens: String([5400, 3400, 2200, 1000][i]),
          cachedTokens: String([3600, 2400, 1400, 600][i]),
          cacheUsageIncomplete: false,
          estimatedMicros: ["18000", "12000", "8000", "4000"][i],
          firstUsedTodayAtUnixSeconds: now - (i + 1) * 3600,
          lastUsedTodayAtUnixSeconds: now - i * 300,
          images: "0",
          priceUsageIncomplete: false,
          lastUsedAtUnixSeconds: now - i * 300,
        })),
      },
    }),
  );
  await page.route("**/api/runtime/storage", (route) =>
    route.fulfill({
      json: {
        pressure: "normal",
        admissionAllowed: true,
        optionalWorkAllowed: true,
        availableBytes: 36 * 1024 ** 3,
        volumeTotalBytes: 64 * 1024 ** 3,
        resources: Array.from({ length: 121 }, (_, i) => ({
          unixSeconds: now - (120 - i) * 30,
          hostCPUPercent: 14 + Math.round(6 * Math.sin(i / 8)),
          processResidentBytes:
            (26 + Math.round(2 * Math.sin(i / 9))) * 1024 ** 2,
          hostAvailableBytes: 3 * 1024 ** 3,
          hostTotalBytes: 4 * 1024 ** 3,
          diskAvailableBytes: 36 * 1024 ** 3,
        })),
      },
    }),
  );
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.setViewportSize({ width: 1440, height: 1200 });
  await mkdir("../docs/assets", { recursive: true });
  await page.goto("/");
  await expect(page.getByText("合成订阅账号", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("img", { name: /^今日已准入近 7 天/ }).locator("svg"),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(
    page
      .getByRole("region", { name: "今日 Key 请求汇总" })
      .getByText("workstation", { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("region", { name: "协议观测" })).toBeVisible();
  await expect.poll(() => Boolean(socket)).toBe(true);
  const sections = await initialSections(page, now);
  Object.assign(sections.inFlight.data, {
    recentRequestOutputRateMedian: 42,
    requestOutputRateByHour: {
      endUnixSeconds: now,
      offsetMinutes: 0,
      points: Object.fromEntries(
        Array.from({ length: 26 }, (_, i) => [
          now - (25 - i) * 3600,
          { median: 35 + Math.round(7 * Math.cos(i / 4)), count: 1 + (i % 3) },
        ]),
      ),
    },
  });
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "docs",
      sequence: 1,
      kind: "snapshot",
      sections,
    }),
  );
  await expect(
    page.getByRole("img", { name: /^Token 输出速率近 7 天/ }),
  ).toBeVisible();
  await page.screenshot({
    path: "../docs/assets/overview.png",
    animations: "disabled",
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.getByRole("link", { name: "访问密钥", exact: false }).click();
  await expect(
    page.getByRole("heading", { name: "访问密钥", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("workstation", { exact: true }).first(),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expectNoHorizontalOverflow(page);
  await page.screenshot({ path: "../docs/assets/keys.png" });
});
