import { z } from "./schema";
export interface AdminSession {
  csrf: string;
}
export class ManagementError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
  ) {
    super("Management request failed");
  }
}
function record(value: unknown): Record<string, unknown> {
  const parsed = z.record(z.string(), z.unknown()).safeParse(value);
  if (!parsed.success) throw new ManagementError(0, "invalid_response");
  return parsed.data;
}
const sessionSchema = z.object({
  authenticated: z.literal(true),
  csrf: z.string().regex(/^ac1_[A-Za-z0-9_-]{43}$/),
});
function parseSession(value: unknown): AdminSession {
  const result = sessionSchema.safeParse(value);
  if (!result.success) throw new ManagementError(0, "invalid_response");
  return { csrf: result.data.csrf };
}
let managementEpoch = 0;
export function retireManagementRequests() {
  managementEpoch += 1;
}
const unauthorized = new Set<() => void>();
export function onUnauthorized(listener: () => void) {
  unauthorized.add(listener);
  return () => {
    unauthorized.delete(listener);
  };
}
export async function request(
  path: string,
  options: {
    method?: string;
    body?: unknown;
    csrf?: string;
    signal?: AbortSignal;
    timeout?: 35000;
  } = {},
): Promise<unknown> {
  const ownerEpoch = managementEpoch;
  const signal = AbortSignal.any([
    AbortSignal.timeout(options.timeout ?? 10_000),
    ...(options.signal ? [options.signal] : []),
  ]);
  try {
    const response = await fetch(path, {
      method: options.method ?? "GET",
      credentials: "same-origin",
      cache: "no-store",
      signal,
      headers: {
        Accept: "application/json",
        ...(options.body === undefined
          ? {}
          : { "Content-Type": "application/json" }),
        ...(options.csrf ? { "X-CodexOne-CSRF": options.csrf } : {}),
      },
      ...(options.body === undefined
        ? {}
        : { body: JSON.stringify(options.body) }),
    });
    if (
      response.status === 401 &&
      ownerEpoch === managementEpoch &&
      !signal.aborted
    ) {
      for (const listener of unauthorized) listener();
    }
    const value: unknown = await response.json();
    if (!response.ok) {
      const error = record(record(value).error);
      throw new ManagementError(
        response.status,
        typeof error.code === "string" && error.code.length <= 80
          ? error.code
          : "management_unavailable",
      );
    }
    return value;
  } catch (error) {
    if (error instanceof ManagementError) throw error;
    throw new ManagementError(0, "connection_failed");
  }
}
export async function fetchSession(
  signal?: AbortSignal,
): Promise<AdminSession> {
  return parseSession(await request("/api/session", { signal }));
}
export async function login(
  secret: string,
  signal?: AbortSignal,
): Promise<AdminSession> {
  return parseSession(
    await request("/api/session", { method: "POST", body: { secret }, signal }),
  );
}
export async function logout(
  csrf: string,
  signal?: AbortSignal,
): Promise<void> {
  await request("/api/session", { method: "DELETE", csrf, signal });
}
