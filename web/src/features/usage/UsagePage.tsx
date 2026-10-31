import { PageHeader } from "../../shared/ui/PageHeader";
import { useNavigationType, useSearchParams } from "react-router";
import { useManagementSession } from "../../shared/session";
import { UsageOverview, usageNavigationKey } from "./UsageOverview";
import { defaults, type UsageFilters } from "./api";
import type { UsageNavigation } from "./UsageOverview";
import { readPage } from "../../shared/view-memory";
export function UsagePage() {
  const restoreView = useNavigationType() === "POP";
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
  // The URL contains filters/page only; cursor history belongs to this session owner.
  function applied(value: UsageFilters, navigation?: UsageNavigation) {
    const next = new URLSearchParams();
    for (const [name, field] of Object.entries(value))
      if (field !== "" && field !== false && field !== undefined)
        next.set(name, String(field));
    next.delete("window");
    if (navigation) {
      next.set("page", String(navigation.page + 1));
      owner.views.set(usageNavigationKey(value, navigation.page), navigation);
    }
    if (next.toString() !== params.toString())
      setParams(next, { replace: true });
  }
  return (
    <section>
      <PageHeader
        title="用量与诊断"
        description="查看请求用量、性能与异常，定位执行与用量证据。"
      />
      <UsageOverview
        initialFilters={filters}
        requestedPage={readPage(params.get("page"), 2201) - 1}
        navigationStore={owner.views}
        restoreView={restoreView}
        selection={null}
        paused={false}
        onUnauthorized={owner.invalidate}
        onApplied={applied}
      />
    </section>
  );
}
