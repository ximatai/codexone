import { queryKeys } from "../../shared/query-keys";
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
    queryKey: [...queryKeys.keys.all, "limits", keyID, refresh],
    queryFn: async ({ signal }) => {
      const keys = await fetchKeys(signal);
      return keys.some((key) => key.id === keyID)
        ? keys
        : [...keys, ...(await fetchKeys(signal, true))];
    },
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
          每日 Token 上限 {formatKeyLimit(key.limits.tokens)} / UTC 日 ·
          最大并发 {formatKeyLimit(key.limits.active)}
        </>
      ) : query.isPending ? (
        "读取中"
      ) : (
        "不可用"
      )}
    </p>
  );
}
