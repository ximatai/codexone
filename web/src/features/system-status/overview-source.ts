import type { UseQueryResult } from "@tanstack/react-query";
import type { Freshness } from "./useOverviewLive";

// Presentation state only: a received unavailable snapshot ends initial loading,
// while the Query cache retains its real data and HTTP request/error lifecycle.
export function overviewQuery<T>(
  query: UseQueryResult<T, Error>,
  source?: Freshness,
) {
  return {
    ...query,
    isPending: query.isPending && !source,
    isFetched: query.isFetched || !!source,
    isError: source
      ? source.freshness !== "fresh" || source.lastSuccessAt == null
      : query.isError,
  };
}
