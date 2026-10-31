import { staticTheme } from "./theme-plugin";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [staticTheme(), react()],
  server: {
    host: "127.0.0.1",
    port: 5179,
    strictPort: true,
    proxy: { "/api": "http://127.0.0.1:18081" },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./tests/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    restoreMocks: true,
  },
});
