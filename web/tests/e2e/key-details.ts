import { expect, type Page } from "@playwright/test";
export async function openKeyDetails(page: Page) {
  if (!(await page.getByRole("link", { name: "查看用量与诊断" }).isVisible())) {
    await expect(page.getByRole("dialog", { name: "密钥详情" })).toBeHidden();
    await page
      .getByRole("row")
      .filter({ hasText: "synthetic-team" })
      .getByRole("button", { name: "查看详情" })
      .click();
  }
}
