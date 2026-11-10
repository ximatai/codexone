import { defineConfig } from "@playwright/test";

const port = Number(process.env.CODEXONE_WEB_TEST_PORT ?? 4173);

export default defineConfig({
  testDir: "./tests/e2e",
  testIgnore: [
    // The separate CI live job supplies a matching gateway and Swift runtime.
    ...(process.env.CODEXONE_WEB_STUBS_ONLY === "1"
      ? ["**/admin-live-real.spec.ts"]
      : []),
    ...(process.env.CODEXONE_DOC_SCREENSHOTS === "1"
      ? []
      : ["**/docs-screenshots.spec.ts"]),
  ],
  timeout: 15_000,
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
    { name: "chrome", use: { browserName: "chromium", channel: "chrome" } },
  ],
  webServer: {
    // Build first (verify.sh --web does this once); exercise the shipped bundle.
    command: `npm run preview -- --host 127.0.0.1 --port ${port} --strictPort`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
