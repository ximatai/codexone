export interface KeyLimits {
  requests: number;
  active: number;
  unresolved: number;
  budgetMicros: number;
  unresolvedMicros: number;
}
export interface ManagedKey {
  id: string;
  principal: string;
  revision: number;
  enabled: boolean;
  models: string[];
  limits: KeyLimits;
  createdAtUnixSeconds: number;
}
export interface KeyDraft { principal: string; models: string[]; limits: KeyLimits }
export interface AdminSession { csrf: string }
export interface KeyCreated { key: ManagedKey; secret: string }

export class ManagementError extends Error {
  constructor(public readonly status: number, public readonly code: string) {
    super("Management request failed");
  }
}
function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new ManagementError(0, "invalid_response");
  return value as Record<string, unknown>;
}
function models(value: unknown, allowEmpty = false): string[] {
  if (!Array.isArray(value) || value.length > 32 || (!allowEmpty && value.length === 0)
      || !value.every((id: unknown) => typeof id === "string" && id.length > 0 && new TextEncoder().encode(id).length <= 128)
      || new Set(value).size !== value.length) throw new ManagementError(0, "invalid_response");
  return value as string[];
}
function boundedNumber(value: unknown, minimum = 1, maximum = 1_000_000_000_000): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new ManagementError(0, "invalid_response");
  return value;
}
export function parseKey(value: unknown): ManagedKey {
  const data = record(value);
  if (typeof data.id !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(data.id)
      || typeof data.principal !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(data.principal)
      || typeof data.enabled !== "boolean") throw new ManagementError(0, "invalid_response");
  const limits = record(data.limits);
  return {
    id: data.id, principal: data.principal, enabled: data.enabled,
    revision: boundedNumber(data.revision, 1, 1_000_000),
    createdAtUnixSeconds: boundedNumber(data.createdAtUnixSeconds, 0), models: models(data.models),
    limits: {
      requests: boundedNumber(limits.requests), active: boundedNumber(limits.active), unresolved: boundedNumber(limits.unresolved),
      budgetMicros: boundedNumber(limits.budgetMicros), unresolvedMicros: boundedNumber(limits.unresolvedMicros),
    },
  };
}
function parseSession(value: unknown): AdminSession {
  const data = record(value);
  if (data.authenticated !== true || typeof data.csrf !== "string" || !/^ac1_[A-Za-z0-9_-]{43}$/.test(data.csrf)) throw new ManagementError(0, "invalid_response");
  return { csrf: data.csrf };
}
function parseCreated(value: unknown): KeyCreated {
  const data = record(value);
  if (typeof data.secret !== "string" || !/^co1_[A-Za-z0-9_-]{43}$/.test(data.secret)) throw new ManagementError(0, "invalid_response");
  return { key: parseKey(data.key), secret: data.secret };
}
async function request(path: string, options: { method?: string; body?: unknown; csrf?: string; signal?: AbortSignal } = {}): Promise<unknown> {
  const signal = AbortSignal.any([AbortSignal.timeout(10_000), ...(options.signal ? [options.signal] : [])]);
  try {
    const response = await fetch(path, {
      method: options.method ?? "GET", credentials: "same-origin", cache: "no-store", signal,
      headers: { Accept: "application/json", ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
        ...(options.csrf ? { "X-CodexOne-CSRF": options.csrf } : {}) },
      ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
    });
    const value: unknown = await response.json();
    if (!response.ok) {
      const error = record(record(value).error);
      throw new ManagementError(response.status, typeof error.code === "string" && error.code.length <= 80 ? error.code : "management_unavailable");
    }
    return value;
  } catch (error) {
    if (error instanceof ManagementError) throw error;
    throw new ManagementError(0, "connection_failed");
  }
}
export async function fetchSession(signal?: AbortSignal): Promise<AdminSession> { return parseSession(await request("/api/session", { signal })); }
export async function login(secret: string, signal?: AbortSignal): Promise<AdminSession> {
  return parseSession(await request("/api/session", { method: "POST", body: { secret }, signal }));
}
export async function logout(csrf: string, signal?: AbortSignal): Promise<void> { await request("/api/session", { method: "DELETE", csrf, signal }); }
export async function fetchOptions(signal?: AbortSignal): Promise<string[]> { return models(record(await request("/api/keys/options", { signal })).models, true); }
export async function fetchKeys(signal?: AbortSignal): Promise<ManagedKey[]> {
  let after: string | null = null;
  const result = new Map<string, ManagedKey>();
  for (let page = 0; page < 5; page++) {
    const value = record(await request("/api/keys" + (after ? "?after=" + encodeURIComponent(after) : ""), { signal }));
    if (!Array.isArray(value.keys) || value.keys.length > 64) throw new ManagementError(0, "invalid_response");
    for (const item of value.keys) { const key = parseKey(item); result.set(key.id, key); }
    if (value.nextCursor === null) return [...result.values()];
    if (typeof value.nextCursor !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(value.nextCursor) || value.nextCursor === after) throw new ManagementError(0, "invalid_response");
    after = value.nextCursor;
  }
  throw new ManagementError(0, "invalid_response");
}
export async function createKey(draft: KeyDraft, csrf: string, signal?: AbortSignal): Promise<KeyCreated> {
  return parseCreated(await request("/api/keys", { method: "POST", body: draft, csrf, signal }));
}
export async function updateKey(key: ManagedKey, enabled: boolean, allowedModels: string[], limits: KeyLimits, csrf: string, signal?: AbortSignal): Promise<ManagedKey> {
  return parseKey(record(await request("/api/keys/" + encodeURIComponent(key.id), { method: "PUT", body: { revision: key.revision, enabled, models: allowedModels, limits }, csrf, signal })).key);
}
export async function rotateKey(key: ManagedKey, csrf: string, signal?: AbortSignal): Promise<KeyCreated> {
  return parseCreated(await request("/api/keys/" + encodeURIComponent(key.id) + "/rotate", { method: "POST", body: { revision: key.revision }, csrf, signal }));
}
