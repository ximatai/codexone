import { mkdir } from "node:fs/promises";
import { expect, test } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { reportFixture } from "../../src/features/usage/usage.test-data";

// Documentation assets contain only generated fixtures; no live API or login.
test("render synthetic documentation screenshots", async ({ page }) => {
  const state = await reviewFixture(page);
  const now = Date.parse("2026-01-15T12:00:00Z") / 1000;
  await page.clock.setFixedTime(new Date(now * 1000));
  state.alerts = 0;
  state.keys.splice(4);
  state.keys.forEach((key, i) => {
    key.principal = ["desktop", "laptop", "terminal", "automation"][i];
    key.expiresAtUnixSeconds = null;
    key.createdAtUnixSeconds = now - 86400;
  });
  state.accounts.splice(1);
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
          succeeded: 12 + i * 2,
          failed: 0,
          cancelled: 0,
          failures: {},
          metrics: report.totals.metrics,
        })),
      },
    }),
  );
  await page.route("**/api/usage/keys", (route) =>
    route.fulfill({
      json: {
        timezone: "UTC",
        startUnixSeconds: Math.floor(now / 86400) * 86400,
        endUnixSeconds: (Math.floor(now / 86400) + 1) * 86400,
        keys: state.keys.map((key, i) => ({
          keyID: key.id,
          principal: key.principal,
          admitted: [8, 6, 6, 4][i],
          failed: 0,
          pending: 0,
          estimatedMicros: "10500",
          lastUsedAtUnixSeconds: now - i * 300,
        })),
      },
    }),
  );
  await page.setViewportSize({ width: 1440, height: 1000 });
  await mkdir("../docs/assets", { recursive: true });
  await page.goto("/");
  await expect(page.getByText("合成订阅账号", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("img", { name: /^今日请求近 7 天/ }),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(
    page.getByText("desktop · synthetic-text").first(),
  ).toBeVisible();
  await page.getByLabel("自动刷新（15 秒）").uncheck();
  await page.screenshot({
    path: "../docs/assets/overview.png",
    fullPage: true,
  });
  await page.getByRole("link", { name: "访问密钥", exact: false }).click();
  await expect(
    page.getByRole("heading", { name: "访问密钥", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("desktop", { exact: true }).first(),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 1440);
  await page.screenshot({ path: "../docs/assets/keys.png" });
});
