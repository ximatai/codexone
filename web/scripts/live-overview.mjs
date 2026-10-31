// Synthetic integration harness: built UI + real temporary gateway, no mocked management API.
import { openChrome } from "./browser.mjs";
import { expect } from "@playwright/test";
import { createServer, request } from "node:http";
import { readFile, mkdir } from "node:fs/promises";
import { resolve, sep, extname } from "node:path";
import { fileURLToPath } from "node:url";

const adminPort = Number(process.argv[2]);
const ready = process.argv[3] === "ready";
const output = resolve(process.argv[4]);
if (!Number.isInteger(adminPort) || adminPort < 1 || adminPort > 65535) throw new Error("Invalid synthetic port");
const root = resolve(fileURLToPath(new URL("../dist/", import.meta.url)));
const server = createServer(async (incoming, outgoing) => {
  if (incoming.url === "/api/system") {
    const proxy = request({ hostname: "127.0.0.1", port: adminPort, path: "/api/system", method: "GET" }, response => {
      outgoing.writeHead(response.statusCode, { "content-type": "application/json" });
      response.pipe(outgoing);
    });
    proxy.on("error", () => { outgoing.writeHead(502); outgoing.end(); });
    proxy.end();
    return;
  }
  const path = resolve(root, "." + new URL(incoming.url, "http://127.0.0.1").pathname);
  if (path !== root && !path.startsWith(root + sep)) { outgoing.writeHead(404); outgoing.end(); return; }
  try {
    const target = path === root ? resolve(root, "index.html") : path;
    const bytes = await readFile(target);
    const contentType = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[extname(target)] ?? "application/octet-stream";
    outgoing.writeHead(200, { "content-type": contentType }); outgoing.end(bytes);
  } catch { outgoing.writeHead(404); outgoing.end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await openChrome();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await expect(page.getByRole("heading", { name: ready ? "网关已就绪" : "网关尚未就绪" })).toBeVisible();
  await expect(page.getByText("连接正常", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "刷新状态" }).click();
  await expect(page.getByRole("heading", { name: ready ? "网关已就绪" : "网关尚未就绪" })).toBeVisible();
  const row = page.getByRole("listitem").filter({ hasText: "执行与用量存储" });
  await expect(row).toContainText(ready ? "已就绪" : "待就绪");
  await mkdir(output, { recursive: true });
  await page.screenshot({ path: resolve(output, ready ? "ready-desktop.png" : "storage-failed-desktop.png"), fullPage: true });
  console.log(`PASS: real management overview ${ready ? "ready" : "storage failure"}, desktop and refresh`);
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
}
