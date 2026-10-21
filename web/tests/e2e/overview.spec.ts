import { readFileSync } from "node:fs";
import { expect, test } from "@playwright/test";

const fixture = readFileSync(new URL("../../../Tests/CodexOneAdaptersTests/Fixtures/system-status.json", import.meta.url), "utf8");

test("overview displays real contract fields at desktop and mobile sizes", async ({ page }) => {
  await page.route("**/api/system", (route) => route.fulfill({ contentType: "application/json", body: fixture }));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "网关尚未就绪" })).toBeVisible();
  await expect(page.getByText("上游账号", { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("button", { name: "刷新状态" })).toBeVisible();
  await expect(page.locator("body")).toHaveJSProperty("scrollWidth", 390);
});

test("connection failure provides a working retry", async ({ page }) => {
  let fail = true;
  await page.route("**/api/system", (route) => fail ? route.abort() : route.fulfill({ contentType: "application/json", body: fixture }));
  await page.goto("/");
  await expect(page.getByRole("alert")).toBeVisible();
  fail = false;
  await page.getByRole("button", { name: "重新连接" }).click();
  await expect(page.getByText("连接正常")).toBeVisible();
});
