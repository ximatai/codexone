export interface SystemStatus {
  service: "codexone";
  ready: boolean;
  transportMode?: "loopback" | "lan_http";
  checks: { name: string; ready: boolean }[];
}

export function parseSystemStatus(value: unknown): SystemStatus {
  if (typeof value !== "object" || value === null)
    throw new Error("Invalid system response");
  const data = value as Record<string, unknown>;
  if (
    data.service !== "codexone" ||
    typeof data.ready !== "boolean" ||
    !Array.isArray(data.checks) ||
    (data.transportMode !== undefined &&
      !["loopback", "lan_http"].includes(data.transportMode as string))
  ) {
    throw new Error("Invalid system response");
  }
  for (const check of data.checks) {
    if (
      typeof check !== "object" ||
      check === null ||
      typeof check.name !== "string" ||
      typeof check.ready !== "boolean"
    ) {
      throw new Error("Invalid system response");
    }
  }
  return {
    service: "codexone",
    ready: data.ready,
    checks: data.checks,
    ...(data.transportMode === undefined
      ? {}
      : { transportMode: data.transportMode as SystemStatus["transportMode"] }),
  };
}

export async function fetchSystemStatus(
  signal: AbortSignal,
): Promise<SystemStatus> {
  const boundedSignal = AbortSignal.any([signal, AbortSignal.timeout(10_000)]);
  const response = await fetch("/api/system", {
    signal: boundedSignal,
    headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new Error("Service unavailable");
  return parseSystemStatus(await response.json());
}
