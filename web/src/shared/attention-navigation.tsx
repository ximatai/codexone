import { createContext, useContext, useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  attentionQueryKey,
  fetchAttention,
} from "../features/system-status/attention-api";

export const AttentionNavigation = createContext<
  ((critical: boolean) => void) | null
>(null);
/** The session-owned query cache reports its marker to the persistent outer shell. */
export function AttentionNavigationObserver() {
  const update = useContext(AttentionNavigation);
  const attention = useQuery({
    queryKey: attentionQueryKey,
    queryFn: ({ signal }) => fetchAttention(signal),
    enabled: false,
  });
  const critical =
    attention.data?.items.some(
      (item) =>
        item.severity === "critical" &&
        (item.kind === "storage_pressure" || item.kind === "backup_stale"),
    ) ?? false;
  useEffect(() => {
    update?.(critical);
    return () => update?.(false);
  }, [critical, update]);
  return null;
}
