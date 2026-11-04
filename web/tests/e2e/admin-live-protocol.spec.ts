import { expect, test } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import type { WebSocketRoute } from "@playwright/test";

test("live metadata preserves content, skipped sequences fall back, and revocation clears private data", async ({
  page,
}) => {
  const state = await reviewFixture(page);
  let socket: WebSocketRoute | undefined;
  await page.routeWebSocket("**/api/overview/live", (route) => {
    socket = route;
  });
  await page.goto("/");
  await expect.poll(() => !!socket).toBe(true);
  const data = await page.evaluate(async () => {
    const paths: Record<string, string> = {
      system: "/api/system",
      inFlight: "/api/usage/in-flight",
      daily: "/api/usage/daily?days=7",
      keys: "/api/usage/keys?includeArchived=false",
      accounts: "/api/accounts",
      storage: "/api/runtime/storage",
      attention: "/api/attention",
      headroom: "/api/usage/headroom",
    };
    return Object.fromEntries(
      await Promise.all(
        Object.entries(paths).map(async ([name, path]) => [
          name,
          await (await fetch(path)).json(),
        ]),
      ),
    );
  });
  data.inFlight = {
    ...data.inFlight,
    recentlyFinished: [],
    clients: [],
    overflow: 0,
  };
  const now = Date.now() / 1000;
  const sections = Object.fromEntries(
    Object.entries(data).map(([name, value]) => [
      name,
      {
        version: 1,
        sampledAtUnixSeconds: now,
        lastSuccessAt: now,
        freshness: "fresh",
        code: null,
        data: value,
      },
    ]),
  );
  const snapshot = {
    protocol: 1,
    epoch: "synthetic-epoch",
    sequence: 1,
    kind: "snapshot",
    sections,
  };
  socket!.send(JSON.stringify(snapshot));
  await expect(page.getByText("实时连接", { exact: true })).toBeVisible();
  const previous =
    (await page
      .getByRole("region", { name: "今日 Key 请求汇总" })
      .textContent()) ?? "";
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 2,
      kind: "update",
      sections: {
        keys: {
          version: 1,
          sampledAtUnixSeconds: now + 1,
          lastSuccessAt: now + 1,
          freshness: "fresh",
          code: null,
        },
      },
    }),
  );
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }),
  ).toHaveText(previous);
  const originalSocket = socket;
  socket!.send(
    JSON.stringify({
      protocol: 1,
      epoch: "synthetic-epoch",
      sequence: 4,
      kind: "update",
      sections: {},
    }),
  );
  await expect(page.getByText("轮询模式（15 秒）· 活动观察中断")).toBeVisible();
  await expect(
    page.getByRole("region", { name: "今日 Key 请求汇总" }),
  ).toHaveText(previous);
  // The HTTP check decides whether a disconnected socket means logout.
  await expect.poll(() => socket !== originalSocket).toBe(true);
  state.anonymous = true;
  socket!.close({ code: 1008 });
  await expect(page.getByRole("heading", { name: "今日运营概览" })).toHaveCount(
    0,
  );
  await expect(page.getByRole("button", { name: "管理员登录" })).toBeVisible();
});
