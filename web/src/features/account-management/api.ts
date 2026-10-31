import {
  parseObservability,
  type AccountObservability,
} from "./observation-api";
import { ManagementError, request } from "../../shared/management";
export type AccountMode = "enabled" | "draining" | "disabled";
export type AccountAuthorization =
  "ready" | "refreshing" | "requires_auth" | "auth_uncertain";
export interface Account {
  id: string;
  displayName?: string | null;
  revision: number;
  credentialVersion: number;
  mode: AccountMode;
  authorization: AccountAuthorization;
  createdAtUnixSeconds: number;
  accessExpiresAtUnixSeconds?: number | null;
  credentialUpdatedAtUnixSeconds?: number | null;
  observability?: AccountObservability;
}
export interface AuthorizationFlow {
  flowID: string;
  authorizationURL: string;
  expiresInSeconds: number;
}
const invalid = () => new ManagementError(0, "invalid_response");
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw invalid();
  return value as Record<string, unknown>;
}
function integer(value: unknown, maximum = 1_000_000): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1 ||
    value > maximum
  )
    throw invalid();
  return value;
}
function id(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(value))
    throw invalid();
  return value;
}
export function parseAccount(raw: unknown): Account {
  const value = object(raw);
  if (
    !["enabled", "draining", "disabled"].includes(String(value.mode)) ||
    !["ready", "refreshing", "requires_auth", "auth_uncertain"].includes(
      String(value.authorization),
    )
  )
    throw invalid();
  return {
    id: id(value.id),
    ...(value.displayName === undefined
      ? {}
      : {
          displayName:
            value.displayName === null ? null : displayName(value.displayName),
        }),
    accessExpiresAtUnixSeconds:
      value.accessExpiresAtUnixSeconds == null
        ? null
        : integer(value.accessExpiresAtUnixSeconds, 1_000_000_000_000),
    credentialUpdatedAtUnixSeconds:
      value.credentialUpdatedAtUnixSeconds == null
        ? null
        : integer(value.credentialUpdatedAtUnixSeconds, 1_000_000_000_000),
    revision: integer(value.revision),
    credentialVersion: integer(value.credentialVersion),
    mode: value.mode as AccountMode,
    authorization: value.authorization as AccountAuthorization,
    createdAtUnixSeconds: integer(
      value.createdAtUnixSeconds,
      1_000_000_000_000,
    ),
    ...(value.observability === undefined
      ? {}
      : { observability: parseObservability(value.observability) }),
  };
}
export async function fetchAccounts(signal?: AbortSignal): Promise<Account[]> {
  const accounts = new Map<string, Account>();
  let after: string | null = null;
  for (let page = 0; page < 2; page++) {
    const started = performance.now();
    const value = object(
      await request(
        "/api/accounts" + (after ? "?after=" + encodeURIComponent(after) : ""),
        { signal },
      ),
    );
    if (!Array.isArray(value.accounts) || value.accounts.length > 64)
      throw invalid();
    for (const raw of value.accounts) {
      const account = parseAccount(raw);
      if (account.observability) account.observability.receivedAt = started;
      if (accounts.has(account.id) || accounts.size >= 64) throw invalid();
      accounts.set(account.id, account);
    }
    if (value.nextCursor === null) return [...accounts.values()];
    const cursor = id(value.nextCursor);
    if (cursor === after || cursor !== value.accounts.at(-1)?.id)
      throw invalid();
    after = cursor;
  }
  throw invalid();
}
export async function setMode(
  account: Account,
  mode: AccountMode,
  csrf: string,
  signal?: AbortSignal,
): Promise<Account> {
  return parseAccount(
    object(
      await request("/api/accounts/" + encodeURIComponent(account.id), {
        method: "PUT",
        body: { revision: account.revision, mode },
        csrf,
        signal,
      }),
    ).account,
  );
}
export async function refreshAccount(
  account: Account,
  csrf: string,
  signal?: AbortSignal,
): Promise<Account> {
  return parseAccount(
    object(
      await request(
        "/api/accounts/" + encodeURIComponent(account.id) + "/refresh",
        {
          method: "POST",
          body: { revision: account.revision },
          csrf,
          signal,
          timeout: 35000,
        },
      ),
    ).account,
  );
}
export async function beginAuthorization(
  account: Account | null,
  csrf: string,
  signal?: AbortSignal,
): Promise<AuthorizationFlow> {
  const value = object(
    await request("/api/accounts/authorization", {
      method: "POST",
      body: {
        target: account ? { id: account.id, revision: account.revision } : null,
      },
      csrf,
      signal,
    }),
  );
  if (
    typeof value.authorizationURL !== "string" ||
    value.authorizationURL.length > 8192
  )
    throw invalid();
  let url: URL;
  try {
    url = new URL(value.authorizationURL);
  } catch {
    throw invalid();
  }
  if (
    url.username ||
    url.password ||
    url.hash ||
    url.pathname !== "/oauth/authorize" ||
    !(
      url.origin === "https://auth.openai.com" ||
      (url.protocol === "http:" && url.hostname === "127.0.0.1" && url.port)
    )
  )
    throw invalid();
  return {
    flowID: id(value.flowID),
    authorizationURL: value.authorizationURL,
    expiresInSeconds: integer(value.expiresInSeconds, 600),
  };
}
export async function completeAuthorization(
  flowID: string,
  callbackURL: string,
  csrf: string,
  signal?: AbortSignal,
): Promise<Account> {
  return parseAccount(
    object(
      await request(
        "/api/accounts/authorization/" + encodeURIComponent(flowID),
        {
          method: "POST",
          body: { callbackURL },
          csrf,
          signal,
          timeout: 35000,
        },
      ),
    ).account,
  );
}
export async function discardAuthorization(
  flowID: string,
  csrf: string,
  signal?: AbortSignal,
): Promise<void> {
  await request("/api/accounts/authorization/" + encodeURIComponent(flowID), {
    method: "DELETE",
    csrf,
    signal,
  });
}

function displayName(value: unknown): string {
  if (
    typeof value !== "string" ||
    [...value].length < 1 ||
    [...value].length > 64 ||
    new TextEncoder().encode(value).length > 256 ||
    /[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u.test(value)
  )
    throw invalid();
  return value;
}
export async function setDisplayName(
  account: Account,
  name: string | null,
  csrf: string,
  signal?: AbortSignal,
): Promise<Account> {
  return parseAccount(
    object(
      await request(
        "/api/accounts/" + encodeURIComponent(account.id) + "/display-name",
        {
          method: "PUT",
          body: {
            revision: account.revision,
            displayName: name === null ? null : displayName(name),
          },
          csrf,
          signal,
        },
      ),
    ).account,
  );
}
