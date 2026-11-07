import { expectNoHorizontalOverflow } from "./layout";
import { expect, test } from "@playwright/test";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { mkdir } from "node:fs/promises";

test("backup attention opens storage details with last success on desktop and mobile", async ({
  page,
}) => {
  const lastSuccess = Math.floor(Date.now() / 1000) - 80 * 3600;
  let mode: "backup" | "blocked" | "normal" = "backup";
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    const data: Record<string, unknown> = {
      "/api/session": { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      "/api/system": { service: "codexone", ready: true, checks: [] },
      "/api/accounts": { accounts: [], nextCursor: null },
      "/api/usage/keys": {
        timezone: "UTC",
        startUnixSeconds: 0,
        endUnixSeconds: 86400,
        keys: [],
      },
      "/api/usage/daily": { timezone: "UTC", days: 7, buckets: [] },
      "/api/usage/in-flight": { rows: [] },
      "/api/usage": { ...reportFixture(), rows: [], nextCursor: null },
      "/api/attention": {
        generatedAtUnixSeconds: 1800000000,
        items:
          mode === "backup"
            ? [
                {
                  kind: "backup_stale",
                  severity: "critical",
                  subjectType: "system",
                  subjectID: null,
                  subjectName: null,
                  detail: {},
                  sinceUnixSeconds: lastSuccess,
                },
                {
                  kind: "backup_size",
                  severity: "warning",
                  subjectType: "system",
                  subjectID: null,
                  subjectName: null,
                  detail: {
                    totalBytes: 6000000000,
                    largestBundleBytes: 800000000,
                  },
                  sinceUnixSeconds: null,
                },
              ]
            : [],
      },
      "/api/runtime/storage": {
        pressure: mode === "blocked" ? "blocked" : "normal",
        admissionAllowed: mode !== "blocked",
        optionalWorkAllowed: mode !== "blocked",
        availableBytes: mode === "blocked" ? 110 * 1024 ** 2 : 9000000000,
        databaseBytes: 1000000,
        walBytes: 0,
        reserveBytes: 67108864,
        backup: {
          enabled: true,
          lastSuccessUnixSeconds: lastSuccess,
          retainedCount: 7,
        },
      },
    };
    return route.fulfill({ json: data[path] ?? {} });
  });
  await page.goto("/");
  await expect(page.getByText("备份超时，请检查磁盘空间。")).toBeVisible();
  await expect(page.getByRole("link", { name: "查看备份" })).toBeVisible();
  await page.getByRole("link", { name: "查看备份" }).click();
  const drawer = page.getByRole("dialog", { name: "存储与准入详情" });
  await expect(drawer.getByText("保留备份：7")).toBeVisible();
  await expect(drawer.getByText(/最近成功备份：/)).not.toContainText("未提供");
  await mkdir("../artifacts/online-backup", { recursive: true });
  await page.waitForTimeout(350);
  await page.screenshot({
    path: "../artifacts/online-backup/storage-1440.png",
  });
  await drawer.getByRole("button", { name: "关闭" }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("link", { name: "查看备份" }).click();
  await expect(drawer.getByText("保留备份：7")).toBeVisible();
  await expectNoHorizontalOverflow(page);
  await page.waitForTimeout(350);
  await page.screenshot({ path: "../artifacts/online-backup/storage-390.png" });
  await drawer.getByRole("button", { name: "关闭" }).click();
  mode = "blocked";
  await page.reload();
  const reminders = page.getByRole("region", { name: "运行提醒" });
  await expect(reminders).toContainText("存储保护已暂停接收新请求");
  await expect(reminders).toContainText("110 MiB");
  await expect(
    page.getByText("存储保护已暂停接收新请求。", { exact: false }),
  ).toHaveCount(1);
  await expectNoHorizontalOverflow(page);
  mode = "normal";
  await page.reload();
  await expect(page.getByRole("group", { name: "数据盘可用" })).toContainText(
    "8.4 GiB",
  );
  await expect(reminders).toHaveCount(0);
});
