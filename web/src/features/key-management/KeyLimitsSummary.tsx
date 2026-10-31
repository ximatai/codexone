import { queryKeys } from "../../shared/query-keys";
import { useQuery } from "@tanstack/react-query";
import { fetchKeys, formatKeyLimit } from "./api";

import { MoneyText } from "../../shared/ui/TimeText";

/** Current policy is separate from the historical usage snapshot. */
export function KeyLimitsSummary({
  keyID,
  refresh = 0,
}: {
  keyID: string;
  refresh?: number;
}) {
  const query = useQuery({
    queryKey: [...queryKeys.keys.all, "limits", keyID, refresh],
    queryFn: ({ signal }) => fetchKeys(signal),
    enabled: !!keyID,
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
          <MoneyText value={key.limits.budgetMicros} unlimited /> ·
          待核对占用阈值{" "}
          <MoneyText value={key.limits.unresolvedMicros} unlimited />
          （美元；仅显式配置生效）
        </>
      ) : query.isPending ? (
        "读取中"
      ) : (
        "不可用"
      )}
    </p>
  );
}
