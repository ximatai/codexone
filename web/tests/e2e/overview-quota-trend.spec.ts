import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { expectNoHorizontalOverflow } from "./layout";

for (const width of [1440, 390]) {
  test(`quota history opens on demand and distinguishes stale data at ${width}px`, async ({
    page,
  }, info) => {
    test.setTimeout(30_000);
    await page.setViewportSize({ width, height: 1000 });
    await page.emulateMedia({
      reducedMotion: width === 390 ? "reduce" : "no-preference",
    });
    const now = new Date("2026-11-09T10:00:00Z");
    await page.clock.setFixedTime(now);
    const state = await reviewFixture(page);
    state.alerts = 0;
    state.keys.splice(1);
    state.accounts.splice(1);
    const account = state.accounts[0];
    account.displayName = "合成订阅";
    const observation = account.observability.quota;
    const at = now.getTime() / 1000;
    const reset = at + 3600;
    observation.observedAtUnixSeconds = at;
    observation.attemptedAtUnixSeconds = at;
    Object.assign(observation.limits[0].primary, {
      usedPercent: 88,
      resetsAtUnixSeconds: reset,
    });
    let reads = 0;
    await page.route("**/api/accounts/*/quota-trend", (route) => {
      reads++;
      return route.fulfill({
        json: {
          primary: {
            reset,
            duration: 18000,
            samples: Array.from({ length: 13 }, (_, i) => [
              at - 3600 + i * 300,
              36 - 2 * i,
            ]),
          },
        },
      });
    });
    await page.goto("/");
    const open = page.getByRole("button", { name: "查看5 小时额度趋势" });
    await expect(open).toBeVisible();
    expect(reads).toBe(0);
    const panelID = await open.getAttribute("aria-controls");
    const panel = page.locator(`[id="${panelID}"]`);
    await panel.evaluate((element) => {
      element.dataset.heightTransitions = "0";
      element.addEventListener("transitionrun", (event) => {
        if (
          event instanceof TransitionEvent &&
          event.target === element.firstElementChild &&
          event.propertyName === "grid-template-rows"
        ) {
          element.dataset.heightTransitions = String(
            Number(element.dataset.heightTransitions) + 1,
          );
        }
      });
    });
    await expect(page.getByText("88% 已用")).toBeVisible();
    await expect(open).toHaveAttribute("title", "剩余 12%");
    const card = page.locator(`[id="${panelID}"]`).locator("../..");
    await card.screenshot({ path: info.outputPath("quota-collapsed.png") });
    await open.focus();
    await open.press("Space");
    const summary = page.getByText("预计约 30 分钟后耗尽");
    const comparison = page.getByText("比重置早 30 分钟");
    await expect(summary).toBeVisible();
    await expect(comparison).toBeVisible();
    const summaryBox = (await summary.boundingBox())!;
    const comparisonBox = (await comparison.boundingBox())!;
    expect(comparisonBox.x).toBeGreaterThan(summaryBox.x + summaryBox.width);
    expect(comparisonBox.y).toBeLessThan(summaryBox.y + summaryBox.height);
    await expect(page.getByRole("img", { name: /剩余额度走势/ })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await page.getByRole("button", { name: "收起5 小时额度趋势" }).blur();
    await page.mouse.move(0, 0);
    await card.screenshot({ path: info.outputPath("quota-trend.png") });

    const positions = () =>
      panel.evaluate((element) => {
        const top = element.getBoundingClientRect().top;
        return [
          element.querySelector('[role="group"]')!.getBoundingClientRect().top -
            top,
          element.querySelector('svg[role="img"]')!.getBoundingClientRect()
            .top - top,
          element.getBoundingClientRect().height,
        ].map(Math.round);
      });
    const predictedPositions = await positions();
    await page.getByRole("button", { name: "8 小时" }).click();
    await expect(page.getByText("额度周期短于所选参考时段")).toBeVisible();
    const status = panel.locator('[aria-live="polite"]');
    await expect(status).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    expect((await status.boundingBox())!.height).toBeLessThan(40);
    expect(await positions()).toEqual(predictedPositions);
    const openingTransitions = Number(
      await panel.getAttribute("data-height-transitions"),
    );
    if (width === 1440) {
      await expect
        .poll(async () =>
          Number(await panel.getAttribute("data-height-transitions")),
        )
        .toBeGreaterThan(0);
    }
    const close = page.getByRole("button", { name: "收起5 小时额度趋势" });
    await close.click();
    await expect(open).toHaveAttribute("aria-expanded", "false");
    await expect(page.getByRole("img", { name: /剩余额度走势/ })).toHaveCount(
      0,
    );

    if (width === 390) {
      await expect(panel).toHaveAttribute("data-height-transitions", "0");
    } else {
      await expect
        .poll(async () =>
          Number(await panel.getAttribute("data-height-transitions")),
        )
        .toBeGreaterThan(openingTransitions);
    }
    await expect(panel.locator("svg")).toHaveCount(0);

    Object.assign(observation, {
      state: "stale",
      ageSeconds: 300,
      freshForSeconds: 0,
    });
    await page.reload();
    await open.click();
    await expect(page.getByText("额度待更新，预测已暂停")).toBeVisible();
    await expect(page.getByRole("img", { name: /剩余额度走势/ })).toBeVisible();
  });
}

test("quota trend distinguishes same-day ticks and explains scenario shading", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const now = new Date("2026-11-10T01:00:00Z");
  await page.clock.setFixedTime(now);
  const state = await reviewFixture(page);
  state.alerts = 0;
  state.accounts.splice(1);
  const observation = state.accounts[0].observability.quota;
  const at = now.getTime() / 1000;
  const reset = at + 23 * 3600;
  const duration = 7 * 86400;
  observation.observedAtUnixSeconds = at;
  observation.attemptedAtUnixSeconds = at;
  Object.assign(observation.limits[0].primary, {
    usedPercent: 88,
    resetsAtUnixSeconds: reset,
    durationSeconds: duration,
  });
  await page.route("**/api/accounts/*/quota-trend", (route) =>
    route.fulfill({
      json: {
        primary: {
          reset,
          duration,
          samples: Array.from({ length: 13 }, (_, i) => [
            at - 3600 + i * 300,
            i <= 6 ? 36 - i : 30 - (i - 6) * 3,
          ]),
        },
      },
    }),
  );
  await page.goto("/");
  await page.getByRole("button", { name: /查看.*额度趋势/ }).click();
  const explanation = "阴影表示较快和较慢消耗情景之间的范围";
  const chart = page.getByRole("img", { name: new RegExp(explanation) });
  await expect(chart).toBeVisible();
  const ticks = await chart.locator('text[y="151"]').allTextContents();
  expect(ticks).toHaveLength(3);
  expect(new Set(ticks).size).toBe(3);
  expect(ticks.every((label) => label.includes(":"))).toBe(true);

  await page.keyboard.press("Tab");
  await expect(page.getByText("预测", { exact: true })).toBeFocused();
  await expect(page.getByRole("tooltip")).toHaveText(explanation);
  await expectNoHorizontalOverflow(page);
});
