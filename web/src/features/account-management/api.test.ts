import { afterEach, expect, it, vi } from "vitest";
import {
  beginAuthorization,
  completeAuthorization,
  fetchAccounts,
  fetchAuthorizationStatus,
  parseAccount,
  setDisplayName,
} from "./api";
const account = {
  id: "account",
  revision: 2,
  credentialVersion: 1,
  mode: "disabled",
  authorization: "ready",
  createdAtUnixSeconds: 1,
  accessExpiresAtUnixSeconds: null,
  credentialUpdatedAtUnixSeconds: null,
};
function reply(value: unknown) {
  return new Response(JSON.stringify(value));
}
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
it("bounds account pages and excludes unknown private response fields", async () => {
  expect(parseAccount({ ...account, access_token: "private" })).toEqual(
    account,
  );
  for (const raw of [
    { ...account, revision: 0 },
    { ...account, mode: "other" },
    { ...account, authorization: "other" },
  ])
    expect(() => parseAccount(raw)).toThrow();
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      reply({ accounts: [account], nextCursor: "account" }),
    )
    .mockResolvedValueOnce(reply({ accounts: [account], nextCursor: null }));
  vi.stubGlobal("fetch", fetch);
  await expect(fetchAccounts()).rejects.toMatchObject({
    code: "invalid_response",
  });
  expect(fetch).toHaveBeenCalledTimes(2);
});
it("rejects unexpected authorization destinations and never replays a callback", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      reply({
        flowID: "flow",
        expiresInSeconds: 600,
        authorizationURL: "https://elsewhere.invalid/oauth/authorize",
      }),
    )
    .mockRejectedValueOnce(new Error("private provider diagnostic"));
  vi.stubGlobal("fetch", fetch);
  await expect(
    beginAuthorization(null, "synthetic-csrf", undefined, "callback"),
  ).rejects.toMatchObject({ code: "invalid_response" });
  const timeout = vi.spyOn(AbortSignal, "timeout");
  await expect(
    completeAuthorization("flow", "private-callback", "synthetic-csrf"),
  ).rejects.toMatchObject({
    code: "connection_failed",
    message: "Management request failed",
  });
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(timeout).toHaveBeenLastCalledWith(35000);
  expect(fetch.mock.calls[1][1].headers).toMatchObject({
    "X-CodexOne-CSRF": "synthetic-csrf",
  });
  expect(fetch.mock.calls[1][1].headers).not.toHaveProperty("Authorization");
});
it("preserves and validates optional display names", () => {
  expect(
    parseAccount({ ...account, displayName: "合成账号" }).displayName,
  ).toBe("合成账号");
  expect(
    parseAccount({ ...account, displayName: null }).displayName,
  ).toBeNull();
  for (const displayName of ["", "a".repeat(65), "a\nb", "a\u200bb"])
    expect(() => parseAccount({ ...account, displayName })).toThrow();
});

it("sends display-name CAS changes and explicit clear with CSRF", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValue(reply({ account: { ...account, displayName: null } }));
  vi.stubGlobal("fetch", fetch);
  await setDisplayName(parseAccount(account), null, "synthetic-csrf");
  expect(fetch.mock.calls[0][0]).toBe("/api/accounts/account/display-name");
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    revision: 2,
    displayName: null,
  });
  expect(fetch.mock.calls[0][1].headers).toMatchObject({
    "X-CodexOne-CSRF": "synthetic-csrf",
  });
});

it("parses only safe credential timestamps and rejects malformed values", () => {
  expect(
    parseAccount({
      ...account,
      accessExpiresAtUnixSeconds: 2000000000,
      credentialUpdatedAtUnixSeconds: 1900000000,
    }),
  ).toMatchObject({
    accessExpiresAtUnixSeconds: 2000000000,
    credentialUpdatedAtUnixSeconds: 1900000000,
  });
  for (const field of [
    "accessExpiresAtUnixSeconds",
    "credentialUpdatedAtUnixSeconds",
  ]) {
    for (const value of [0, -1, "secret", 1.5])
      expect(() => parseAccount({ ...account, [field]: value })).toThrow();
  }
});

it("defaults to device and validates its public fields without retaining private provider data", async () => {
  const fetch = vi.fn().mockResolvedValue(
    reply({
      flowID: "device-flow",
      method: "device",
      expiresInSeconds: 900,
      userCode: "SYNTH-CODE",
      verificationURL: "https://auth.openai.com/codex/device",
      intervalSeconds: 3,
      device_auth_id: "private-provider-material",
    }),
  );
  vi.stubGlobal("fetch", fetch);
  const flow = await beginAuthorization(null, "synthetic-csrf");
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    target: null,
    method: "device",
  });
  expect(flow).not.toHaveProperty("device_auth_id");
  expect(JSON.stringify(flow)).not.toContain("private-provider-material");
  fetch.mockResolvedValue(
    reply({
      ...flow,
      verificationURL: "https://elsewhere.invalid/codex/device",
    }),
  );
  await expect(
    beginAuthorization(null, "synthetic-csrf"),
  ).rejects.toMatchObject({ code: "invalid_response" });
});

it.each([
  "provider_rejected",
  "exchange_failed",
  "identity_mismatch",
  "verification_failed",
  "revision_conflict",
  "device_code_unavailable",
  "authorization_failed",
  "future_failure",
])(
  "accepts failure code %s in creation and status responses",
  async (failureCode) => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(
        reply({
          flowID: "synthetic-flow",
          method: "device",
          expiresInSeconds: 900,
          failureCode,
        }),
      )
      .mockResolvedValueOnce(
        reply({ status: "failed", expiresInSeconds: 899, failureCode }),
      );
    vi.stubGlobal("fetch", fetch);
    expect((await beginAuthorization(null, "synthetic-csrf")).failureCode).toBe(
      failureCode,
    );
    expect((await fetchAuthorizationStatus("synthetic-flow")).failureCode).toBe(
      failureCode,
    );
  },
);
it.each([42, null, "private provider prose", "a".repeat(65), "bad\ncode"])(
  "rejects malformed failure code %s",
  async (failureCode) => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue(
          reply({ status: "failed", expiresInSeconds: 899, failureCode }),
        ),
    );
    await expect(
      fetchAuthorizationStatus("synthetic-flow"),
    ).rejects.toMatchObject({ code: "invalid_response" });
  },
);
