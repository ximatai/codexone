import { expect, test } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";

test("overview keeps accessible trends, principal names, details and responsive layout", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const screenshots = "../artifacts/ui-phase2";
  await mkdir(screenshots, { recursive: true });
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
      observability: observationFixture(),
    };
    const report = reportFixture();
    const data: Record<string, unknown> = {
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
      },
      "/api/usage/keys": {
        timezone: "UTC",
        startUnixSeconds: 0,
        endUnixSeconds: 86400,
        keys: [
          {
            keyID: "synthetic-key",
            principal: "合成工作站",
            admitted: 8,
            failed: 1,
            pending: 0,
            estimatedMicros: "1250000",
            lastUsedAtUnixSeconds: 1,
          },
        ],
      },
      "/api/usage/daily": {
        timezone: "UTC",
        days: 7,
        buckets: Array.from({ length: 7 }, (_, i) => ({
          atUnixSeconds: i * 86400,
          requests: 10 + i * 2,
          succeeded: 9 + i * 2,
          failed: 1,
          cancelled: 0,
          failures: { rate_limited: 1 },
          metrics,
        })),
      },
      "/api/usage/in-flight": {
        rows: [
          {
            id: "synthetic-flight",
            keyID: "hidden-key-identifier",
            principal: "合成工作站",
            model: "synthetic-text",
            mode: "generation",
            accountID: account.id,
            accountDisplayName: account.displayName,
            elapsedSeconds: 12,
            hasFirstEvent: true,
          },
        ],
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
  await expect(
    page.getByRole("heading", { name: "今日运营概览" }),
  ).toBeVisible();
  await expect(
    page.getByRole("img", { name: /^今日请求近 7 天/ }),
  ).toBeVisible();
  await expect(
    page.getByText("合成工作站 · synthetic-text").first(),
  ).toBeVisible();
  await expect(page.getByText("hidden-key-identifier")).toHaveCount(0);
  await page.getByLabel("自动刷新（15 秒）").uncheck();
  await page.waitForTimeout(400);
  await page.screenshot({ path: screenshots + "/overview-1440.png" });
  const recent = page
    .getByRole("row")
    .filter({ hasText: "1.2 s / 14.0 s" })
    .first();
  await recent.focus();
  await recent.press("Enter");
  await expect(page.getByRole("dialog", { name: "请求详情" })).toContainText(
    "request-first",
  );
  await page.waitForTimeout(350);
  await page.screenshot({ path: screenshots + "/overview-detail-1440.png" });
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
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(350);
  await page.screenshot({ path: screenshots + "/overview-390.png" });
});
