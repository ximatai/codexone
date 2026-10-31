import type { Page } from "@playwright/test";
import { reportFixture } from "../../src/features/usage/usage.test-data";
import { observationFixture } from "../../src/features/account-management/observation.test-data";
export async function reviewFixture(page: Page) {
  const now = Math.floor(Date.now() / 1000);
  const keys = Array.from({ length: 204 }, (_, i) => ({
    id: `synthetic-key-${i}`,
    principal: `team-${i}`,
    displayName: null,
    revision: 1,
    enabled: i % 4 !== 3,
    models: ["synthetic-text"],
    createdAtUnixSeconds: 1,
    expiresAtUnixSeconds:
      i % 4 === 1 ? now + 3 * 86400 : i % 4 === 2 ? now - 3600 : null,
    limits: {
      requests: 1000,
      active: 4,
      unresolved: 8,
      budgetMicros: 1000000,
      unresolvedMicros: null,
    },
  }));
  const accounts = Array.from({ length: 5 }, (_, i) => ({
    id: `synthetic-account-${i}`,
    displayName:
      i === 0 ? "LongUnbrokenAccountDisplayName".repeat(2) : `合成账号 ${i}`,
    revision: 1,
    credentialVersion: 1,
    mode: "enabled",
    authorization:
      i === 1 ? "requires_auth" : i === 2 ? "auth_uncertain" : "ready",
    createdAtUnixSeconds: 1,
    observability: observationFixture(),
  }));
  const state = {
    keys,
    accounts,
    failures: {} as Record<string, number>,
    empty: false,
    anonymous: false,
    alerts: 2,
    reads: [] as { path: string; query: string }[],
    writes: [] as { path: string; body: Record<string, unknown> }[],
  };
  await page.context().route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== "http://127.0.0.1:4173")
      return route.abort("blockedbyclient");
    const path = url.pathname;
    if (!path.startsWith("/api/")) return route.continue();
    const method = route.request().method();
    if (method === "GET") state.reads.push({ path, query: url.search });
    if (state.failures[path])
      return route.fulfill({
        status: state.failures[path],
        json: { error: { code: "synthetic_unavailable" } },
      });
    if (path === "/api/session")
      return route.fulfill({
        status: state.anonymous ? 401 : 200,
        json: state.anonymous
          ? { error: { code: "unauthorized" } }
          : { authenticated: true, csrf: "ac1_" + "a".repeat(43) },
      });
    if (method !== "GET") {
      const body = route.request().postDataJSON();
      state.writes.push({ path, body });
      const key = keys.find((key) => path.includes(`/${key.id}/`));
      if (key) {
        Object.assign(key, body);
        key.revision++;
        return route.fulfill({
          json: path.endsWith("/rotate")
            ? { key, secret: "co1_" + "s".repeat(43) }
            : { key },
        });
      }
      return route.fulfill({
        status: 400,
        json: { error: { code: "synthetic_invalid" } },
      });
    }
    const offset = Number(
      url.searchParams.get("after")?.replace("cursor-", "") ?? "0",
    );
    const report = { ...reportFixture(), nextCursor: null as string | null };
    report.rows = state.empty
      ? []
      : Array.from({ length: 50 }, (_, i) => ({
          ...report.rows[0],
          id: `execution-${offset + i}`,
          requestID: `request-${offset + i}`,
          principal: "team-0",
        }));
    report.nextCursor =
      offset < 450 && !state.empty ? `cursor-${offset + 50}` : null;
    const data: Record<string, unknown> = {
      "/api/system": { service: "codexone", ready: true, checks: [] },
      "/api/keys/options": { models: ["synthetic-text"], imageModels: [] },
      "/api/accounts": {
        accounts: state.empty ? [] : accounts,
        nextCursor: null,
      },
      "/api/usage/options": {
        keys: keys.map((k) => k.id),
        models: ["synthetic-text"],
        failures: [],
      },
      "/api/usage": report,
      "/api/usage/keys": {
        timezone: "UTC",
        startUnixSeconds: Math.floor(now / 86400) * 86400,
        endUnixSeconds: (Math.floor(now / 86400) + 1) * 86400,
        keys: keys.map((key) => ({
          keyID: key.id,
          principal: key.principal,
          admitted: 980,
          failed: 0,
          pending: 0,
          estimatedMicros: "1234",
          lastUsedAtUnixSeconds: now,
        })),
      },
      "/api/usage/daily": { timezone: "UTC", days: 7, buckets: [] },
      "/api/usage/in-flight": { rows: [] },
      "/api/usage/headroom": {
        generatedAtUnixSeconds: now,
        capacities: [],
        accounts: [],
        storage: { pressure: "normal" },
        storageLimits: {},
        unknownReconciliation: {
          count: 0,
          beforeUnixSeconds: now - 86400,
          periodSeconds: 86400,
        },
      },
      "/api/runtime/storage": {
        pressure: "normal",
        admissionAllowed: true,
        optionalWorkAllowed: true,
      },
      "/api/attention": {
        generatedAtUnixSeconds: now,
        items: Array.from({ length: state.alerts }, (_, i) => ({
          kind: i === 0 ? "account_requires_auth" : "key_expiring",
          severity: i === 0 ? "critical" : "warning",
          subjectType: i === 0 ? "account" : "key",
          subjectID: i === 0 ? accounts[1].id : keys[201].id,
          subjectName: i === 0 ? accounts[1].displayName : keys[201].principal,
          detail: {},
          sinceUnixSeconds: now,
        })),
      },
    };
    if (path === "/api/keys") {
      const after =
        keys.findIndex((key) => key.id === url.searchParams.get("after")) + 1;
      return route.fulfill({
        json: {
          keys: state.empty ? [] : keys.slice(after, after + 64),
          nextCursor:
            !state.empty && after + 64 < keys.length
              ? keys[after + 63].id
              : null,
        },
      });
    }
    if (path.endsWith("/observation"))
      return route.fulfill({ json: observationFixture() });
    return route.fulfill({
      status: path in data ? 200 : 404,
      json: data[path] ?? { error: { code: "synthetic_missing" } },
    });
  });
  return state;
}
