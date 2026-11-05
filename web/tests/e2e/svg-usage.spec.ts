import { expect, test, gotoUsage } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { mkdir } from "node:fs/promises";

for (const width of [1440, 390]) {
  test(`SVG author counters remain complete with unknown price at ${width}px`, async ({
    page,
  }) => {
    const report = reportFixture();
    const metrics = {
      ...report.rows[0].metrics,
      inputTokens: "20",
      svgInputTokens: "10",
      svgOutputTokens: "20",
      svgReasoningTokens: "5",
      priceCompleteness: "partial",
    };
    await page.route("**/api/**", (route) => {
      const path = new URL(route.request().url()).pathname;
      if (path === "/api/session")
        return route.fulfill({
          json: { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
        });
      if (path === "/api/usage/options")
        return route.fulfill({
          json: { keys: ["alpha"], models: ["synthetic-text"], failures: [] },
        });
      if (path === "/api/usage")
        return route.fulfill({
          json: {
            ...report,
            totals: { ...report.totals, metrics },
            rows: [
              {
                ...report.rows[0],
                metrics,
                svgAuthorModel: "synthetic-author",
                usageMissingReasons: ["svg_price_unavailable"],
              },
            ],
          },
        });
      return route.fulfill({
        status: 404,
        json: { error: { code: "synthetic_not_configured" } },
      });
    });
    await page.setViewportSize({ width, height: 900 });
    await gotoUsage(page, new Date("2026-10-22T12:00:00Z"));
    await page.locator(".usage-table tbody tr").first().click();
    const drawer = page.getByRole("dialog", { name: "请求详情" });
    await expect(drawer.getByText("用量：完整", { exact: true })).toBeVisible();
    await expect(
      drawer.getByText("作者费率未知", { exact: true }),
    ).toBeVisible();
    await expect(
      drawer.getByText("SVG 作者输入 token", { exact: true }),
    ).toBeVisible();
    await expect(drawer).toContainText("SVG 作者模型：synthetic-author");
    await drawer
      .getByText("SVG 作者输入 token", { exact: true })
      .scrollIntoViewIfNeeded();
    await expect(
      drawer.getByText("SVG 作者输入 token", { exact: true }),
    ).toBeInViewport();
    await expectNoHorizontalOverflow(page);
    await mkdir("../artifacts/svg-usage", { recursive: true });
    await page.screenshot({
      path: `../artifacts/svg-usage/detail-${width}.png`,
      animations: "disabled",
    });
  });
}
