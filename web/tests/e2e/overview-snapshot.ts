import type { Page } from "@playwright/test";

export async function initialSections(page: Page, now = Date.now() / 1000) {
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
  return sections;
}
