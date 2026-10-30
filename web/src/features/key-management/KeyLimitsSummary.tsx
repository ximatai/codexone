import { useQuery } from "@tanstack/react-query";
import { fetchKeys, formatKeyLimit } from "./api";

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
          {formatKeyLimit(key.limits.active)} · 未结执行{" "}
          {formatKeyLimit(key.limits.unresolved)} · 每日估算阈值{" "}
          {formatKeyLimit(key.limits.budgetMicros)} · 未结暴露阈值{" "}
          {formatKeyLimit(key.limits.unresolvedMicros)}（微单位）
        </>
      ) : query.isPending ? (
        "读取中"
      ) : (
        "不可用"
      )}
    </p>
  );
}
