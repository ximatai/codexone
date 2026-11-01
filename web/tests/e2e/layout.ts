import { expect, type Page } from "@playwright/test";

/** Compare content with the usable width, which excludes classic scrollbars. */
export async function expectNoHorizontalOverflow(page: Page) {
  await expect
    .poll(() =>
      page.evaluate(() => {
        const root = document.documentElement;
        return {
          documentOverflows: root.scrollWidth > root.clientWidth,
          bodyOverflows: document.body.scrollWidth > root.clientWidth,
        };
      }),
    )
    .toEqual({ documentOverflows: false, bodyOverflows: false });
}
