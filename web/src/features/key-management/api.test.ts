import { afterEach, expect, it, vi } from "vitest";
import {
  createKey,
  fetchKeys,
  fetchSession,
  login,
  parseKey,
  updateKey,
  setExpiration,
  setDisplayName,
} from "./api";
const csrf = "ac1_" + "a".repeat(43);
const secret = "co1_" + "b".repeat(43);
const key = {
  id: "key-1",
  principal: "team",
  revision: 7,
  enabled: false,
  models: ["synthetic-text"],
  limits: {
    requests: 10,
    active: 2,
    unresolved: 4,
    budgetMicros: 1000,
    unresolvedMicros: 1000,
  },
  createdAtUnixSeconds: 1,
};
function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), { status });
}
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
it("uses cookies and CSRF without retaining or replaying administrator credentials", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(reply({ authenticated: true, csrf }))
    .mockResolvedValueOnce(reply({ key, secret }))
    .mockResolvedValueOnce(reply({ key }));
  vi.stubGlobal("fetch", fetch);
  await login("admin", "synthetic-admin-input");
  expect(fetch.mock.calls[0][1]).toMatchObject({
    credentials: "same-origin",
    cache: "no-store",
    body: JSON.stringify({
      username: "admin",
      secret: "synthetic-admin-input",
    }),
  });
  expect(
    (
      await createKey(
        { principal: key.principal, models: key.models, limits: key.limits },
        csrf,
      )
    ).secret,
  ).toBe(secret);
  await updateKey(key, true, key.models, key.limits, csrf);
  for (const [, options] of fetch.mock.calls.slice(1)) {
    expect(options.headers).toMatchObject({ "X-CodexOne-CSRF": csrf });
    expect(JSON.stringify(options)).not.toContain("synthetic-admin-input");
    expect(options.headers).not.toHaveProperty("Authorization");
  }
  expect(JSON.parse(fetch.mock.calls[2][1].body)).toMatchObject({
    revision: 7,
    enabled: true,
  });
});
it("rejects malformed permissions, unsafe numbers and cycling pagination", async () => {
  expect(parseKey(key).enabled).toBe(false);
  for (const value of [
    { ...key, revision: 0 },
    { ...key, models: [] },
    { ...key, models: ["x", "x"] },
    { ...key, limits: { ...key.limits, requests: Number.MAX_SAFE_INTEGER } },
  ]) {
    expect(() => parseKey(value)).toThrow();
  }
  const fetch = vi
    .fn()
    .mockImplementation(() =>
      Promise.resolve(reply({ keys: [key], nextCursor: "key-1" })),
    );
  vi.stubGlobal("fetch", fetch);
  await expect(fetchKeys()).rejects.toMatchObject({ code: "invalid_response" });
  expect(fetch).toHaveBeenCalledTimes(2);
});
it("does not retry a mutation after transport loss or expose upstream error prose", async () => {
  const fetch = vi
    .fn()
    .mockRejectedValueOnce(new Error("private diagnostic"))
    .mockResolvedValueOnce(
      reply(
        { error: { code: "revision_conflict", message: "private diagnostic" } },
        409,
      ),
    );
  vi.stubGlobal("fetch", fetch);
  await expect(createKey(key, csrf)).rejects.toMatchObject({
    status: 0,
    message: "Management request failed",
  });
  expect(fetch).toHaveBeenCalledTimes(1);
  await expect(
    updateKey(key, true, key.models, key.limits, csrf),
  ).rejects.toMatchObject({
    status: 409,
    code: "revision_conflict",
    message: "Management request failed",
  });
});
it("bounds stalled session response bodies and supports a fresh attempt", async () => {
  const controller = new AbortController();
  const timer = vi
    .spyOn(AbortSignal, "timeout")
    .mockReturnValue(controller.signal);
  vi.stubGlobal(
    "fetch",
    vi
      .fn()
      .mockImplementationOnce((_url, options) =>
        Promise.resolve({
          ok: true,
          json: () =>
            new Promise((_resolve, reject) =>
              options.signal.addEventListener(
                "abort",
                () => reject(options.signal.reason),
                { once: true },
              ),
            ),
        }),
      )
      .mockResolvedValueOnce(reply({ authenticated: true, csrf })),
  );
  const pending = fetchSession();
  const rejected = expect(pending).rejects.toMatchObject({ status: 0 });
  await Promise.resolve();
  controller.abort();
  await rejected;
  expect(timer).toHaveBeenCalledWith(10_000);
  timer.mockRestore();
  expect(await fetchSession()).toEqual({ csrf });
});

it("round-trips explicit nulls and rejects missing or invalid limit fields", async () => {
  const limits = {
    requests: null,
    active: null,
    unresolved: null,
    budgetMicros: null,
    unresolvedMicros: null,
  };
  expect(parseKey({ ...key, limits }).limits).toEqual(limits);
  for (const field of Object.keys(limits)) {
    const missing: Record<string, unknown> = { ...limits };
    delete missing[field];
    expect(() => parseKey({ ...key, limits: missing })).toThrow();
    for (const invalid of [0, -1, 1_000_000_000_001, "invalid", true])
      expect(() =>
        parseKey({ ...key, limits: { ...limits, [field]: invalid } }),
      ).toThrow();
  }
  const fetch = vi
    .fn()
    .mockResolvedValue(reply({ key: { ...key, limits }, secret }));
  vi.stubGlobal("fetch", fetch);
  expect((await createKey({ ...key, limits }, csrf)).key.limits).toEqual(
    limits,
  );
  expect(JSON.parse(fetch.mock.calls[0][1].body).limits).toEqual(limits);
});

it("sets and clears expiration with a revision and never retries conflicts", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      reply({ key: { ...key, expiresAtUnixSeconds: 2000000 } }),
    )
    .mockResolvedValueOnce(
      reply({ key: { ...key, expiresAtUnixSeconds: null } }),
    )
    .mockResolvedValueOnce(
      reply({ error: { code: "revision_conflict" } }, 409),
    );
  vi.stubGlobal("fetch", fetch);
  expect((await setExpiration(key, 2000000, csrf)).expiresAtUnixSeconds).toBe(
    2000000,
  );
  expect(
    (await setExpiration(key, null, csrf)).expiresAtUnixSeconds,
  ).toBeNull();
  expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({
    revision: 7,
    expiresAtUnixSeconds: null,
  });
  await expect(setExpiration(key, null, csrf)).rejects.toMatchObject({
    status: 409,
  });
  expect(fetch).toHaveBeenCalledTimes(3);
});

it("sets and clears display names using CAS without retrying conflicts", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      reply({ key: { ...key, revision: 8, displayName: "合成别名" } }),
    )
    .mockResolvedValueOnce(
      reply({ key: { ...key, revision: 9, displayName: null } }),
    )
    .mockResolvedValueOnce(
      reply({ error: { code: "revision_conflict" } }, 409),
    );
  vi.stubGlobal("fetch", fetch);
  const named = await setDisplayName(key, "合成别名", csrf);
  expect(named.displayName).toBe("合成别名");
  expect((await setDisplayName(named, null, csrf)).displayName).toBeNull();
  await expect(setDisplayName(key, "stale", csrf)).rejects.toMatchObject({
    status: 409,
  });
  expect(fetch).toHaveBeenCalledTimes(3);
  expect(fetch.mock.calls[0][0]).toBe("/api/keys/key-1/display-name");
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    revision: 7,
    displayName: "合成别名",
  });
});

it("preserves null model scopes through parse and update without treating missing fields as all", async () => {
  const all = {
    ...key,
    models: null,
    imageGeneration: true,
    imageModels: null,
  };
  expect(parseKey(all)).toMatchObject({ models: null, imageModels: null });
  const missing = { ...all } as Record<string, unknown>;
  delete missing.models;
  expect(() => parseKey(missing)).toThrow();
  const fetch = vi.fn().mockResolvedValue(reply({ key: all }));
  vi.stubGlobal("fetch", fetch);
  await updateKey(all, false, null, all.limits, csrf);
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
    models: null,
    imageModels: null,
  });
});

it("keeps the archived filter on every cursor page", async () => {
  const archived = { ...key, archivedAtUnixSeconds: 100 };
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(reply({ keys: [archived], nextCursor: key.id }))
    .mockResolvedValueOnce(reply({ keys: [], nextCursor: null }));
  vi.stubGlobal("fetch", fetch);
  expect(await fetchKeys(undefined, true)).toEqual([parseKey(archived)]);
  expect(fetch.mock.calls.map(([url]) => url)).toEqual([
    "/api/keys?archived=true",
    "/api/keys?archived=true&after=key-1",
  ]);
});
