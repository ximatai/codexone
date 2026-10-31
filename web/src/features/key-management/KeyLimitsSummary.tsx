import { useQuery } from "@tanstack/react-query";
import { fetchKeys, formatKeyLimit } from "./api";

import { money } from "../../shared/presentation";

/** Current policy is separate from the historical usage snapshot. */
export function KeyLimitsSummary({
  keyID,
  refresh = 0,
}: {
  keyID: string;
  refresh?: number;
}) {
  const query = useQuery({
    queryKey: ["key-limits", keyID, refresh],
    queryFn: ({ signal }) => fetchKeys(signal),
    enabled: !!keyID,
    retry: false,
    gcTime: 0,
  });
  const key = query.data?.find((entry) => entry.id === keyID);
  if (!keyID) return null;
  return (
    <p>
      当前 Key 限额：
      {key ? (
        <>
          每日请求 {formatKeyLimit(key.limits.requests)} · 同时执行{" "}
          {formatKeyLimit(key.limits.active)} · 待核对请求{" "}
          {formatKeyLimit(key.limits.unresolved)} · 每日估算阈值{" "}
          {money(key.limits.budgetMicros, true)} · 待核对占用阈值{" "}
          {money(key.limits.unresolvedMicros, true)}（美元）
        </>
      ) : query.isPending ? (
        "读取中"
      ) : (
        "不可用"
      )}
    </p>
  );
}
