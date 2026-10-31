import { Title } from "@mantine/core";
import { useSearchParams } from "react-router";
import { useManagementSession } from "../../shared/session";
import { UsageOverview } from "./UsageOverview";
import { defaults, type UsageFilters } from "./api";
export function UsagePage() {
  const [params, setParams] = useSearchParams();
  const owner = useManagementSession();
  const filters: UsageFilters = { ...defaults() };
  for (const key of [
    "start",
    "end",
    "key",
    "model",
    "mode",
    "failure",
    "state",
  ] as const) {
    if (params.has(key)) filters[key] = params.get(key)!;
  }
  if (params.get("range") === "24h") filters.range = "24h";
  filters.failedOnly = params.get("failedOnly") === "true";
  // Only filters go into the URL. Request cursors and all authentication data remain local.
  function applied(value: UsageFilters) {
    const next = new URLSearchParams();
    for (const [name, field] of Object.entries(value))
      if (field !== "" && field !== false && field !== undefined)
        next.set(name, String(field));
    if (next.toString() !== params.toString())
      setParams(next, { replace: true });
  }
  return (
    <section>
      <Title order={1} mb="xl">
        用量与诊断
      </Title>
      <UsageOverview
        initialFilters={filters}
        selection={null}
        paused={false}
        onUnauthorized={owner.invalidate}
        onApplied={applied}
      />
    </section>
  );
}
