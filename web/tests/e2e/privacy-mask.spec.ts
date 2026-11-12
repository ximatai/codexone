import { test, expect } from "./fixtures";
import { reviewFixture } from "./ui-review-fixture";
import { expectNoHorizontalOverflow } from "./layout";

test("masks account and Key names without exposing them in titles or resetting on navigation", async ({
  page,
}, info) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.emulateMedia({ reducedMotion: "reduce" });
  const state = await reviewFixture(page);
  state.alerts = 0;
  state.accounts.splice(1);
  state.accounts[0].displayName = "合成隐私账号";
  state.keys.splice(1);
  state.keys[0].principal = "synthetic-private-key-label";
  await page.goto("/");
  const toggle = page.getByRole("button", { name: "截图隐私模式" });
  const account = page.getByText("合成隐私账号", { exact: true });
  const key = page.getByText("synthetic-private-key-label", { exact: true });
  await expect(account).toBeVisible();
  await expect(key).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-pressed", "false");

  await toggle.focus();
  await toggle.press("Enter");
  await expect(toggle).toHaveAttribute("aria-pressed", "true");
  await expect(account).toHaveCount(0);
  await expect(key).toHaveCount(0);
  await expect(
    page.locator('[title*="synthetic-private-key-label"]'),
  ).toHaveCount(0);
  await expect(page.getByRole("img", { name: "已隐藏" }).first()).toBeVisible();
  await toggle.blur();
  await page.screenshot({ path: info.outputPath("privacy-home.png") });

  await page.goto("/#/?account=synthetic-account-0");
  const drawer = page.getByRole("dialog", { name: "账号详情" });
  await expect(
    drawer.getByRole("img", { name: "已隐藏" }).first(),
  ).toBeVisible();
  await expect(account).toHaveCount(0);
  await drawer.getByRole("tab", { name: "设置" }).click();
  await expect(drawer.getByLabel("账号显示名")).toHaveAttribute(
    "type",
    "password",
  );
  await drawer.getByRole("button", { name: "关闭", exact: true }).click();

  await page.getByRole("link", { name: "访问密钥", exact: true }).click();
  await expect(
    page.getByRole("row", { name: "访问密钥 · 已隐藏" }),
  ).toBeVisible();
  await expect(key).toHaveCount(0);
  await page.reload();
  await expect(toggle).toHaveAttribute("aria-pressed", "true");
  await expect(key).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(toggle).toBeVisible();
  await expectNoHorizontalOverflow(page);
  await toggle.click();
  await expect(key).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-pressed", "false");
});
