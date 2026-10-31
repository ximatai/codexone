// Started outside an agent sandbox; prints the endpoint sandboxed tests connect to.
import { chromium } from "@playwright/test";

const server = await chromium.launchServer({
  channel: "chrome",
  headless: true,
  host: "127.0.0.1",
  chromiumSandbox: true,
});
console.log(server.wsEndpoint());
const stop = () => server.close().finally(() => process.exit(0));
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
