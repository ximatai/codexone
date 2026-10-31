import { defineConfig } from "@playwright/test";

const port = Number(process.env.CODEXONE_WEB_TEST_PORT ?? 4173);

export default defineConfig({
  testDir: "./tests/e2e",
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
    command: `npm run dev -- --port ${port} --strictPort`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
