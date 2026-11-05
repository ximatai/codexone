import { test as base, expect, type Page } from "@playwright/test";

/** Every test owns a synthetic API boundary, including reads it did not explicitly mock. */
export const test = base.extend<{ syntheticBoundary: void }>({
  syntheticBoundary: [
    async ({ context, baseURL }, use) => {
      const origin = new URL(baseURL!).origin;
      // HTTP interception does not intercept WebSockets. Keep mocked tests inside their
      // synthetic boundary; the dedicated real-stack test imports Playwright directly.
      await context.routeWebSocket("**/api/overview/live", (socket) =>
        socket.close({ code: 1013 }),
      );
      await context.route("**/*", (route) => {
        const url = new URL(route.request().url());
        if (url.origin !== origin) return route.abort("blockedbyclient");
        if (url.pathname.startsWith("/api/"))
          return route.fulfill({
            status: 404,
            json: { error: { code: "synthetic_not_configured" } },
          });
        return route.continue();
      });
      await use();
    },
    { auto: true },
  ],
});
export { expect };

/** Keep the initial read from replacing the URL while the next interaction starts. */
export async function gotoUsage(page: Page, now = new Date()) {
  await page.clock.setFixedTime(now);
  const start = new Date(now.getTime() - 6 * 86400000)
    .toISOString()
    .slice(0, 10);
  const end = now.toISOString().slice(0, 10);
  await page.goto(`/#/usage?start=${start}&end=${end}&page=1`);
}
