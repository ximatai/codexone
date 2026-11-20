import { expect, test } from "./fixtures";
import { expectNoHorizontalOverflow } from "./layout";
import { reviewFixture } from "./ui-review-fixture";

test("reviews enabled model profile changes before applying incompatible settings", async ({
  page,
}) => {
  await reviewFixture(page);
  const current = {
    id: "demo-sol",
    state: "enabled",
    visionInput: false,
    reasoningEfforts: ["high"],
    supportedReasoningEfforts: ["medium", "high"],
    defaultReasoningEffort: "high",
    contextWindow: 272_000,
    maxContextWindow: 500_000,
  };
  const replacement = {
    ...current,
    visionInput: true,
    reasoningEfforts: ["medium"],
    supportedReasoningEfforts: ["medium"],
    defaultReasoningEffort: "medium",
    contextWindow: 500_000,
    maxContextWindow: 1_000_000,
    resetReasoningRequired: true,
  };
  let applied = false;
  const candidateRevision = "00000000-0000-4000-8000-000000000000";
  const document = () => ({
    revision: applied ? 5 : 4,
    active: [
      applied ? replacement : { ...current, profileUpdate: replacement },
    ],
    retired: [],
    candidates: [],
    imageModels: [],
    account: "synthetic-account",
    candidateRevision,
    fetchedAt: 1_785_000_000,
  });
  await page.route("**/api/models", (route) =>
    route.fulfill({ json: document() }),
  );
  await page.route("**/api/accounts", (route) =>
    route.fulfill({ json: { accounts: [], nextCursor: null } }),
  );
  await page.route("**/api/models/profile", async (route) => {
    expect(route.request().method()).toBe("PUT");
    expect(route.request().postDataJSON()).toEqual({
      model: current.id,
      revision: 4,
      candidateRevision,
      resetReasoningSettings: true,
    });
    applied = true;
    await route.fulfill({ json: document() });
  });
  await page.goto("/#/models");
  await page.getByRole("button", { name: "资料更新", exact: true }).click();
  const modal = page.getByRole("dialog", { name: "更新模型资料" });
  await expect(modal.getByText("最大窗口 500,000 → 1,000,000")).toBeVisible();
  await expect(
    modal.getByText("获视觉输入权限且可使用该模型的 Key 将可以处理图片。"),
  ).toBeVisible();
  const save = modal.getByRole("button", { name: "确认更新", exact: true });
  await expect(save).toBeDisabled();
  await modal.getByRole("checkbox").check();
  await save.click();
  await expect(modal).not.toBeVisible();
  await expect(
    page.getByRole("button", { name: "资料更新", exact: true }),
  ).toHaveCount(0);
  await expect(page.getByText("模型资料已更新。")).toBeVisible();
});

for (const width of [1320, 390]) {
  test(`updates model and Key reasoning settings at ${width}px`, async ({
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
      supportedReasoningEfforts: reasoningEfforts,
      profileDefaultReasoningEffort: "medium",
      configuredDefaultReasoningEffort: null as string | null,
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
            ...(active.some((item) => item.id === "gpt-5.6-luna")
              ? []
              : [model("gpt-5.6-luna", "candidate")]),
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
          revision: 1,
          candidateRevision: "00000000-0000-4000-8000-000000000000",
          model: "gpt-5.6-luna",
          enabled: true,
          inputMicrosPerMillion: 200_000,
          outputMicrosPerMillion: 1_234_567,
          allowedReasoningEfforts: ["medium", "high"],
          defaultReasoningEffort: "high",
        });
        revision++;
        active.push({
          ...model("gpt-5.6-luna", "enabled"),
          reasoningEfforts: ["medium", "high"],
          configuredDefaultReasoningEffort: "high",
          defaultReasoningEffort: "high",
        });
      }
      await route.fulfill({ json: document() });
    });
    await page.route("**/api/models/reasoning", async (route) => {
      expect(route.request().postDataJSON()).toEqual({
        revision: 0,
        model: "demo-sol",
        allowedReasoningEfforts: ["low", "medium", "high"],
        defaultReasoningEffort: "high",
      });
      revision++;
      active[0] = {
        ...active[0],
        reasoningEfforts: ["low", "medium", "high"],
        defaultReasoningEffort: "high",
        configuredDefaultReasoningEffort: "high",
      };
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
          "gpt-5.6-luna": ["high"],
        });
        key.models = draft.models;
        key.reasoningEfforts = draft.reasoningEfforts;
        key.revision++;
        return route.fulfill({ json: { key } });
      }
      return route.fulfill({ json: { keys: [key], nextCursor: null } });
    });
    await page.goto("/#/models");
    await page.getByRole("button", { name: "推理设置" }).first().click();
    const settings = page.getByRole("dialog", { name: "推理设置" });
    await settings.getByRole("checkbox", { name: "xhigh" }).uncheck();
    await settings.getByRole("combobox", { name: "默认档位" }).click();
    await page.getByRole("option", { name: "high", exact: true }).click();
    await expectNoHorizontalOverflow(page);
    await settings.getByRole("button", { name: "保存" }).click();
    await expect(page.getByText("推理设置已保存。")).toBeVisible();
    await expect(page.getByText("默认 high", { exact: true })).toBeVisible();
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
    await expect(
      confirmation.getByRole("textbox", { name: "输入费率" }),
    ).toHaveValue("0.20");
    await expect(
      confirmation.getByRole("textbox", { name: "输出费率" }),
    ).toHaveValue("1.20");
    await confirmation
      .getByRole("textbox", { name: "输出费率" })
      .fill("1.234567");
    await confirmation
      .getByRole("checkbox", { name: "low", exact: true })
      .uncheck();
    await confirmation.getByRole("checkbox", { name: "xhigh" }).uncheck();
    await confirmation.getByRole("combobox", { name: "默认档位" }).click();
    await page.getByRole("option", { name: "high", exact: true }).click();
    await expectNoHorizontalOverflow(page);
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
    await drawer.getByRole("checkbox", { name: "gpt-5.6-luna" }).check();
    await drawer.getByRole("radio", { name: "指定档位" }).check();
    for (const effort of ["medium"]) {
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

test("edits active model rates at microdollar precision and reloads after a conflict", async ({
  page,
}) => {
  await reviewFixture(page);
  await page.setViewportSize({ width: 390, height: 900 });
  const active = {
    id: "demo-sol",
    state: "enabled",
    reasoningEfforts: [],
    defaultReasoningEffort: null,
    inputMicrosPerMillion: 1,
    outputMicrosPerMillion: 500_000_000,
  };
  let revision = 4;
  const document = () => ({
    revision,
    active: [active],
    retired: [{ ...active, id: "demo-retired", state: "retired" }],
    candidates: [],
    imageModels: ["demo-image"],
    account: null,
    fetchedAt: null,
  });
  await page.route("**/api/models", (route) =>
    route.fulfill({ json: document() }),
  );
  await page.route("**/api/accounts", (route) =>
    route.fulfill({ json: { accounts: [], nextCursor: null } }),
  );
  await page.route("**/api/models/rates", async (route) => {
    expect(route.request().method()).toBe("PUT");
    expect(route.request().postDataJSON()).toEqual({
      revision,
      model: active.id,
      inputMicrosPerMillion: 1_234_567,
      outputMicrosPerMillion: 0,
    });
    revision++;
    if (revision === 5) {
      active.inputMicrosPerMillion = 2_000_000;
      return route.fulfill({
        status: 409,
        json: { error: { code: "revision_conflict" } },
      });
    }
    active.inputMicrosPerMillion = 1_234_567;
    active.outputMicrosPerMillion = 0;
    await route.fulfill({ json: document() });
  });
  await page.goto("/#/models");
  await expect(
    page.getByText("输入 0.000001 · 输出 500 美元／百万 Token"),
  ).toBeVisible();
  const edit = page.getByRole("button", { name: "编辑费率", exact: true });
  await expect(edit).toHaveCount(1);
  await edit.click();
  const modal = page.getByRole("dialog", { name: "编辑模型费率" });
  const input = modal.getByLabel("输入费率（美元／百万 Token）");
  const output = modal.getByLabel("输出费率（美元／百万 Token）");
  const save = modal.getByRole("button", { name: "保存", exact: true });
  await expect(input).toHaveValue("0.000001");
  await expect(output).toHaveValue("500");
  await expectNoHorizontalOverflow(page);
  await input.clear();
  await expect(save).toBeDisabled();
  await input.fill("1.234567");
  await output.fill("0");
  await save.click();
  await expect(
    modal.getByText("目录已变化，请关闭后重新打开费率编辑。"),
  ).toBeVisible();
  await expect(save).toBeDisabled();
  await modal.getByRole("button", { name: "取消" }).click();
  await edit.click();
  await expect(input).toHaveValue("2");
  await input.fill("1.234567");
  await output.fill("0");
  await save.click();
  await expect(modal).not.toBeVisible();
  await expect(
    page.getByText("输入 1.234567 · 输出 0 美元／百万 Token"),
  ).toBeVisible();
});
