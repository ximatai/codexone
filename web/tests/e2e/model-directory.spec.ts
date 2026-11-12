import { expect, test } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";
import { reviewFixture } from "./ui-review-fixture";

for (const width of [1320, 390]) {
  test(`activates a discovered model and saves per-Key reasoning at ${width}px`, async ({
    page,
  }, info) => {
    await reviewFixture(page);
    await page.setViewportSize({ width, height: 900 });
    const model = (
      id: string,
      state: string,
      reasoningEfforts = ["low", "medium", "high", "xhigh"],
    ) => ({
      id,
      state,
      reasoningEfforts,
      defaultReasoningEffort: "medium",
    });
    const active = [
      model("demo-sol", "enabled"),
      model("demo-terra", "enabled", ["medium", "high", "xhigh"]),
      model("demo-luna", "enabled", ["low", "medium", "high"]),
    ];
    let refreshed = false;
    let revision = 0;
    const document = () => ({
      revision,
      active,
      imageModels: ["demo-image"],
      retired: [
        {
          ...model("demo-legacy", "retired"),
          visionInput: true,
          previousVisionInput: false,
        },
      ],
      candidates: refreshed
        ? [
            ...(revision === 0 ? [model("demo-nova", "candidate")] : []),
            model("demo-edge", "incomplete"),
          ]
        : [],
      account: refreshed ? "synthetic-account-0" : null,
      candidateRevision: refreshed
        ? "00000000-0000-4000-8000-000000000000"
        : null,
      fetchedAt: refreshed ? 1_785_000_000 : null,
    });
    await page.route("**/api/models", async (route) => {
      if (route.request().method() === "PUT") {
        expect(route.request().postDataJSON()).toEqual({
          revision: 0,
          candidateRevision: "00000000-0000-4000-8000-000000000000",
          model: "demo-nova",
          enabled: true,
          inputMicrosPerMillion: 0,
          outputMicrosPerMillion: 0,
        });
        revision++;
        active.push(model("demo-nova", "enabled"));
      }
      await route.fulfill({ json: document() });
    });
    await page.route("**/api/accounts/*/model-candidates", async (route) => {
      refreshed = true;
      await route.fulfill({ json: document() });
    });
    await page.route("**/api/accounts", (route) =>
      route.fulfill({
        json: {
          accounts: [
            {
              id: "synthetic-account-0",
              displayName: "演示订阅账号",
              revision: 1,
              credentialVersion: 1,
              mode: "enabled",
              authorization: "ready",
              createdAtUnixSeconds: 1,
            },
          ],
          nextCursor: null,
        },
      }),
    );
    await page.route("**/api/keys/options", (route) =>
      route.fulfill({
        json: {
          models: active.map((item) => item.id),
          imageModels: ["demo-image"],
          reasoningEfforts: Object.fromEntries(
            active.map((item) => [item.id, item.reasoningEfforts]),
          ),
        },
      }),
    );
    const key = {
      id: "synthetic-key-0",
      displayName: "日常开发",
      principal: "demo-dev",
      revision: 1,
      enabled: true,
      models: ["demo-sol", "demo-luna"],
      imageModels: [],
      reasoningEfforts: { "demo-sol": ["low", "medium"] } as Record<
        string,
        string[]
      >,
      visionInput: true,
      imageGeneration: false,
      createdAtUnixSeconds: 1_785_000_000,
      limits: { tokens: 10_000_000, active: 4 },
    };
    await page.route("**/api/keys**", (route) => {
      if (new URL(route.request().url()).pathname === "/api/keys/options")
        return route.fallback();
      if (route.request().method() === "PUT") {
        const draft = route.request().postDataJSON();
        expect(draft.reasoningEfforts).toEqual({
          "demo-sol": ["low", "medium"],
          "demo-nova": ["high"],
        });
        key.models = draft.models;
        key.reasoningEfforts = draft.reasoningEfforts;
        key.revision++;
        return route.fulfill({ json: { key } });
      }
      return route.fulfill({ json: { keys: [key], nextCursor: null } });
    });
    await page.goto("/#/models");
    await page.getByRole("button", { name: "刷新候选" }).click();
    await expect(page.getByText("demo-edge", { exact: true })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    if (width === 1320) {
      await page.screenshot({
        path: info.outputPath("model-directory.png"),
        fullPage: true,
        animations: "disabled",
      });
    }
    await page.getByRole("button", { name: "重新启用" }).click();
    await expect(page.getByText(/此模型新增视觉输入能力/)).toBeVisible();
    await page
      .getByRole("dialog", { name: "启用模型" })
      .getByRole("button", { name: "取消" })
      .click();
    await page.getByRole("button", { name: "审核并启用" }).click();
    const confirmation = page.getByRole("dialog", { name: "启用模型" });
    await expect(
      confirmation.getByText(
        "启用后，选择「全部模型」的 Key 会自动获得此模型。",
      ),
    ).toBeVisible();
    await confirmation.getByRole("textbox", { name: "输入费率" }).fill("0");
    await confirmation.getByRole("textbox", { name: "输出费率" }).fill("0");
    await confirmation.getByRole("button", { name: "确认启用" }).click();
    await expect(
      page.getByText("模型已启用，可在 Key 权限中选择。"),
    ).toBeVisible();
    await page
      .getByRole("link", { name: "访问密钥", exact: true })
      .last()
      .click();
    await page.getByRole("button", { name: "查看详情" }).click();
    const drawer = page.getByRole("dialog");
    await drawer.getByRole("checkbox", { name: "demo-nova" }).check();
    await drawer.getByRole("radio", { name: "指定档位" }).check();
    for (const effort of ["low", "medium", "xhigh"]) {
      await drawer
        .getByRole("checkbox", { name: effort, exact: true })
        .uncheck();
    }
    await expect(
      drawer.getByRole("button", { name: "保存修改" }),
    ).toBeInViewport();
    await expectNoHorizontalOverflow(page);
    await page.screenshot({
      path: info.outputPath("key-reasoning.png"),
      animations: "disabled",
    });
    const response = page.waitForResponse(
      (entry) =>
        entry.request().method() === "PUT" &&
        entry.url().endsWith("/api/keys/synthetic-key-0"),
    );
    await drawer.getByRole("button", { name: "保存修改" }).click();
    expect((await response).ok()).toBe(true);
  });
}
