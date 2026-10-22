import { afterEach, expect, it, vi } from "vitest";
import { beginAuthorization, completeAuthorization, fetchAccounts, parseAccount } from "./api";
const account = { id: "account", revision: 2, credentialVersion: 1, mode: "disabled", authorization: "ready", createdAtUnixSeconds: 1 };
function reply(value: unknown) { return new Response(JSON.stringify(value)); }
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it("bounds account pages and excludes unknown private response fields", async () => {
  expect(parseAccount({ ...account, access_token: "private" })).toEqual(account);
  for (const raw of [{ ...account, revision: 0 }, { ...account, mode: "other" }, { ...account, authorization: "other" }]) expect(() => parseAccount(raw)).toThrow();
  const fetch = vi.fn().mockResolvedValueOnce(reply({ accounts: [account], nextCursor: "account" }))
    .mockResolvedValueOnce(reply({ accounts: [account], nextCursor: null }));
  vi.stubGlobal("fetch", fetch);
  await expect(fetchAccounts()).rejects.toMatchObject({ code: "invalid_response" });
  expect(fetch).toHaveBeenCalledTimes(2);
});
it("rejects unexpected authorization destinations and never replays a callback", async () => {
  const fetch = vi.fn().mockResolvedValueOnce(reply({ flowID: "flow", expiresInSeconds: 600, authorizationURL: "https://elsewhere.invalid/oauth/authorize" }))
    .mockRejectedValueOnce(new Error("private provider diagnostic"));
  vi.stubGlobal("fetch", fetch);
  await expect(beginAuthorization(null, "synthetic-csrf")).rejects.toMatchObject({ code: "invalid_response" });
  const timeout = vi.spyOn(AbortSignal, "timeout");
  await expect(completeAuthorization("flow", "private-callback", "synthetic-csrf")).rejects.toMatchObject({ code: "connection_failed", message: "Management request failed" });
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(timeout).toHaveBeenLastCalledWith(35000);
  expect(fetch.mock.calls[1][1].headers).toMatchObject({ "X-CodexOne-CSRF": "synthetic-csrf" });
  expect(fetch.mock.calls[1][1].headers).not.toHaveProperty("Authorization");
});
