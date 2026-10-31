// Sandboxed agents cannot start Chrome (macOS seatbelt denies its Mach
// registration); they connect to a browser server started outside instead.
import { chromium } from "@playwright/test";

export function openChrome() {
  const endpoint = process.env.PW_TEST_CONNECT_WS_ENDPOINT;
  return endpoint
    ? chromium.connect(endpoint)
    : chromium.launch({ channel: "chrome", headless: true });
}
