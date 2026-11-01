import { test, expect } from "@playwright/test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync } from "node:fs";
import { mkdtemp, writeFile, rm, mkdir } from "node:fs/promises";
import { createServer } from "node:net";
import {
  createServer as createHTTPServer,
  request as requestHTTP,
} from "node:http";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { expectNoHorizontalOverflow } from "./layout";

const probe = resolve("../.build/debug/ExecutionProbe");

test("LAN HTTP logs in, retains the warning across pages, creates a Key and logs out through the real admin API", async ({
  browser,
}) => {
  // The standalone Node-only frontend CI has no Swift executable. Backend-capable runs must build
  // ExecutionProbe first; verify.sh --backend followed by --web exercises this actual API path.
  test.skip(
    !existsSync(probe),
    "Build ExecutionProbe to run the actual LAN HTTP browser contract",
  );
  test.setTimeout(30_000);
  const root = await mkdtemp(join(tmpdir(), "codexone-lan-ui-"));
  const secret = "synthetic-lan-browser-admin-credential-only";
  await writeFile(join(root, "admin"), secret, { mode: 0o600 });
  const reservation = createServer();
  reservation.listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const port = (reservation.address() as { port: number }).port;
  await new Promise<void>((resolve) => reservation.close(() => resolve()));
  const origin = `http://192.168.1.10:${port}`;
  // Chromium skips DNS rules for literal IPs. This test-only HTTP proxy keeps the original
  // private Host/Origin and real browser cookie handling, while forwarding solely to our API.
  const relay = createHTTPServer((request, response) => {
    const target = new URL(request.url!, origin);
    if (target.origin !== origin) {
      response.writeHead(403).end();
      return;
    }
    const upstream = requestHTTP(
      {
        host: "127.0.0.1",
        port,
        path: target.pathname + target.search,
        method: request.method,
        headers: request.headers,
        timeout: 5000,
      },
      (reply) => {
        response.writeHead(reply.statusCode!, reply.headers);
        reply.pipe(response);
      },
    );
    upstream.on("timeout", () => upstream.destroy());
    upstream.on("error", () => {
      response.writeHead(502).end();
    });
    request.on("aborted", () => upstream.destroy());
    request.pipe(upstream);
  });
  relay.maxConnections = 32;
  relay.requestTimeout = 10_000;
  relay.listen(0, "127.0.0.1");
  await once(relay, "listening");
  const relayPort = (relay.address() as { port: number }).port;
  const context = await browser.newContext({
    proxy: { server: `http://127.0.0.1:${relayPort}` },
  });
  const page = await context.newPage();
  const child = spawn(
    probe,
    ["--lan-admin-ui", root, resolve("dist"), String(port)],
    {
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  try {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Synthetic LAN admin did not start")),
        10_000,
      );
      child.once("exit", () => {
        clearTimeout(timer);
        reject(new Error("Synthetic LAN admin exited"));
      });
      child.stdout.on("data", (data: Buffer) => {
        if (data.toString().includes("LAN_ADMIN_READY")) {
          clearTimeout(timer);
          resolve();
        }
      });
    });
    const errors: string[] = [];
    page.on("pageerror", () => errors.push("page error"));
    page.on("console", (entry) => {
      if (
        /content security policy|refused to execute|refused to apply/i.test(
          entry.text(),
        )
      )
        errors.push("CSP error");
    });
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(origin + "/#/keys");
    const banner = page.getByRole("alert", { name: "局域网明文风险" });
    await expect(banner).toContainText(
      "局域网 HTTP 模式：管理员秘密、Key 与请求内容在局域网中明文传输",
    );
    await expect(
      banner.getByRole("link", { name: "了解风险" }),
    ).toHaveAttribute("href", /#局域网-http-风险$/);
    await page.getByLabel("管理员凭证", { exact: true }).fill(secret);
    await page.getByRole("button", { name: "登录管理台", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "创建密钥", exact: true }),
    ).toBeEnabled();
    const cookie = (await context.cookies(origin)).find(
      (item) => item.name === "codexone_admin",
    );
    expect(cookie).toMatchObject({
      secure: false,
      httpOnly: true,
      sameSite: "Strict",
      path: "/",
    });
    await page.getByRole("button", { name: "创建密钥", exact: true }).click();
    await page
      .getByLabel("主体标识", { exact: true })
      .fill("synthetic-lan-device");
    await page
      .getByRole("checkbox", { name: "synthetic-text", exact: true })
      .check();
    await page
      .getByRole("dialog", { name: "创建密钥", exact: true })
      .getByRole("button", { name: "创建密钥", exact: true })
      .click();
    const dialog = page.getByRole("dialog", { name: "保存一次性凭证" });
    await expect(dialog).toBeVisible();
    await dialog.getByRole("button", { name: "我已保存，关闭" }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(
      page.getByRole("row").filter({ hasText: "synthetic-lan-device" }),
    ).toBeVisible();
    await mkdir("../artifacts", { recursive: true });
    await expectNoHorizontalOverflow(page);
    await page.screenshot({
      path: "../artifacts/lan-http-1440.png",
      fullPage: true,
    });
    await page.reload();
    await expect(
      page.getByRole("row").filter({ hasText: "synthetic-lan-device" }),
    ).toBeVisible();
    await expect(banner).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    await expectNoHorizontalOverflow(page);
    await page.screenshot({
      path: "../artifacts/lan-http-390.png",
      fullPage: true,
    });
    // Hash navigation leaves the banner mounted even while the protected feature changes.
    await page.goto(origin + "/#/usage");
    await expect(banner).toBeVisible();
    await page.getByRole("button", { name: "退出登录", exact: true }).click();
    await expect(
      page.getByRole("heading", { name: "管理员登录" }),
    ).toBeVisible();
    await expect(banner).toBeVisible();
    expect(
      (await context.cookies(origin)).some(
        (item) => item.name === "codexone_admin",
      ),
    ).toBe(false);
    expect(
      await page.evaluate(() => [localStorage.length, sessionStorage.length]),
    ).toEqual([0, 0]);
    expect(errors).toEqual([]);
  } finally {
    await context.close();
    relay.closeAllConnections();
    await new Promise<void>((resolve) => relay.close(() => resolve()));
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGTERM");
      await exited;
    }
    await rm(root, { recursive: true, force: true });
  }
});
