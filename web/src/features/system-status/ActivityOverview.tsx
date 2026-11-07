import { overviewQuery } from "./overview-source";
import type { useOverviewLive } from "./useOverviewLive";
import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
import { useQuery } from "@tanstack/react-query";
import {
  Anchor,
  Badge,
  Button,
  Group,
  Paper,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router";
import { ErrorState } from "../../shared/ui/States";
import styles from "./overview.module.css";
import { OverviewStats, OutputRateTrend } from "./OverviewStats";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { localTime } from "../../shared/presentation";
import { KeyResults } from "./KeyResults";
import { fetchDaily, fetchInFlight, fetchKeySummary } from "./round2-api";
import { useOverviewRefresh } from "./useOverviewRefresh";
const reasoningLabels: Record<string, string> = {
  minimal: "最低",
  low: "低",
  medium: "中",
  high: "高",
  xhigh: "极高",
};
const outputRateFormat = new Intl.NumberFormat("zh-CN", {
  maximumFractionDigits: 2,
});
function Elapsed({
  seconds,
  sampledAt,
  running = true,
}: {
  seconds: number | null | undefined;
  sampledAt: number;
  running?: boolean;
}) {
  const [basis, setBasis] = useState(() => ({
    sampledAt,
    at: performance.now(),
  }));
  const [now, setNow] = useState(() => performance.now());
  if (basis.sampledAt !== sampledAt)
    setBasis({ sampledAt, at: performance.now() });
  useEffect(() => {
    if (!running) return;
    const timer = window.setInterval(() => {
      if (!document.hidden) setNow(performance.now());
    }, 1000);
    return () => window.clearInterval(timer);
  }, [running]);
  return (
    <span style={{ fontVariantNumeric: "tabular-nums" }}>
      {seconds == null
        ? "耗时未知"
        : `${Math.floor(seconds + (running ? Math.max(0, now - basis.at) / 1000 : 0))} 秒`}
    </span>
  );
}
export function ActivityOverview({
  refresh,
  extraQueries = [],
  sidebar,
  accounts = [],
  live,
}: {
  live?: ReturnType<typeof useOverviewLive>;
  refresh?: ReturnType<typeof useOverviewRefresh>;
  extraQueries?: {
    source: string;
    isError: boolean;
    dataUpdatedAt: number;
    isFetching: boolean;
    refetch: () => Promise<unknown>;
  }[];
  sidebar?: (outputTrend: ReactNode) => ReactNode;
  accounts?: readonly AccountName[];
}) {
  const owner = useManagementSession();
  const localRefresh = useOverviewRefresh();
  const control = refresh ?? localRefresh;
  const options = {
    enabled: !!owner.session,
    refetchInterval: control.interval,
    // Returning to the tab refetches only snapshots older than one refresh period.
    refetchOnWindowFocus: control.active && live?.mode !== "live",
    refetchOnReconnect: control.active && live?.mode !== "live",
    staleTime: 15000,
  };
  const daily = overviewQuery(
    useQuery({
      queryKey: ["overview", "daily"],
      queryFn: ({ signal }) => fetchDaily(signal),
      ...options,
    }),
    live?.sources.daily,
  );
  const flight = overviewQuery(
    useQuery({
      queryKey: ["overview", "in-flight"],
      queryFn: ({ signal }) => fetchInFlight(signal),
      ...options,
    }),
    live?.sources.inFlight,
  );
  // All overview snapshots share the same pause and refresh cadence.
  const keySummary = overviewQuery(
    useQuery({
      queryKey: ["overview", "keys"],
      queryFn: ({ signal }) => fetchKeySummary(signal),
      ...options,
    }),
    live?.sources.keys,
  );
  const queries = [daily, flight, keySummary];
  const allQueries = [
    ...queries.map((query, index) => ({
      ...query,
      source: ["运营指标", "进行中请求", "今日 Key 汇总"][index],
    })),
    ...extraQueries,
  ];
  const unauthorized = queries.some(
    (q) => q.error instanceof ManagementError && q.error.status === 401,
  );
  useEffect(() => {
    if (unauthorized) owner.invalidate();
  }, [unauthorized, owner]);
  if (!owner.session) return null;
  const failedSources = allQueries.filter((query) => query.isError);
  const readFailure = failedSources.length
    ? `读取失败 · ${failedSources
        .map(
          (query) =>
            `${query.source}${query.dataUpdatedAt ? `（上次更新 ${localTime(query.dataUpdatedAt / 1000)}）` : "（无数据）"}`,
        )
        .join("、")}`
    : "";
  const retrySources = () => {
    if (live?.mode === "live") {
      live.retry();
      return;
    }
    for (const query of failedSources) void query.refetch();
  };

  const connectionNotice = live ? (
    <div
      className={styles.connectionNotice}
      aria-label="概览连接状态"
      data-live-mode={live.mode}
      data-live-failure={live.failure || undefined}
      hidden={!readFailure && !live.stale.length && !live.overflow}
    >
      {readFailure ? (
        <Group gap={4} align="flex-start" wrap="nowrap">
          <Text
            size="xs"
            c="red"
            role="alert"
            className={styles.connectionNoticeText}
          >
            {readFailure}
          </Text>
          <Button variant="subtle" size="xs" onClick={retrySources}>
            重试
          </Button>
        </Group>
      ) : (
        !!live.stale.length && (
          <Text size="xs" c="orange.8">
            {live.stale.length} 项数据待更新
          </Text>
        )
      )}
      {!!live.overflow && (
        <Text size="xs" c="dimmed">
          另有 {live.overflow} 条活动，请到用量页查看。
        </Text>
      )}
    </div>
  ) : failedSources.length > 0 ? (
    <ErrorState retry={retrySources}>{readFailure}</ErrorState>
  ) : null;

  return (
    <Stack
      aria-label="请求即时概览"
      className={styles.overview}
      gap="var(--overview-gap)"
    >
      <div className={sidebar ? styles.content : undefined}>
        <Stack className={styles.main} gap="var(--overview-gap)">
          {daily.isError && !daily.data ? (
            <Text size="sm" c="dimmed">
              指标读取失败
            </Text>
          ) : (
            <OverviewStats
              buckets={daily.data?.buckets ?? []}
              timezone={daily.data?.timezone}
              offsetMinutes={daily.data?.businessDay.offsetMinutes}
              loading={daily.isPending}
            />
          )}
          <Paper withBorder p="md">
            <Title order={3} size="h4" mb="xs">
              进行中请求
              {live?.settledOutputRate != null && (
                <Text
                  component="span"
                  size="xs"
                  c="dimmed"
                  title="最近 60 秒内，仅对有输出 Token 结算的秒数取平均。"
                >
                  {" · "}
                  {outputRateFormat.format(live.settledOutputRate)} Token/s
                </Text>
              )}
            </Title>
            {live?.flightUnconfirmed && (
              <Text size="xs" c="orange.8" role="status">
                正在核对请求，显示上次状态。
              </Text>
            )}
            {flight.isError && !flight.data ? (
              <Text size="sm" c="dimmed">
                在途请求读取失败
              </Text>
            ) : flight.isPending || !flight.data?.length ? (
              <Text size="sm" c="dimmed" className={styles.requestEmpty}>
                {flight.isPending ? "读取中…" : "暂无进行中请求"}
              </Text>
            ) : (
              <div className={styles.requestGrid} aria-label="在途请求卡片">
                {[...flight.data]
                  .sort(
                    (a, b) =>
                      (a.startedAtUnixSeconds ?? Number.MAX_SAFE_INTEGER) -
                        (b.startedAtUnixSeconds ?? Number.MAX_SAFE_INTEGER) ||
                      a.id.localeCompare(b.id),
                  )
                  .map((row) => {
                    const name =
                      row.displayName ??
                      (row.principal?.startsWith("legacy-p-")
                        ? null
                        : row.principal) ??
                      "未命名 Key";
                    const account = row.accountID
                      ? accountName(
                          row.accountID,
                          accounts,
                          row.accountDisplayName,
                        )
                      : null;
                    return (
                      <Paper
                        key={row.id}
                        withBorder
                        p="xs"
                        className={styles.requestCard}
                      >
                        <Group justify="space-between" wrap="nowrap" gap={4}>
                          <Text size="sm" fw={600} truncate title={name}>
                            {name}
                          </Text>
                          <Text size="xs" className={styles.requestElapsed}>
                            <Elapsed
                              seconds={row.elapsedSeconds}
                              sampledAt={flight.dataUpdatedAt}
                              running={
                                control.active &&
                                !flight.isError &&
                                !live?.flightUnconfirmed &&
                                (!live ||
                                  !live.stale.some(
                                    ([source]) => source === "inFlight",
                                  ))
                              }
                            />
                          </Text>
                        </Group>
                        <Group wrap="nowrap" gap={5}>
                          <Text
                            size="xs"
                            truncate
                            title={row.model ?? undefined}
                          >
                            {row.model ?? "模型未知"}
                          </Text>
                          {row.reasoningEffort && (
                            <Badge
                              size="xs"
                              color="gray"
                              variant="light"
                              className={styles.requestEffort}
                              title={`推理强度：${reasoningLabels[row.reasoningEffort] ?? row.reasoningEffort}`}
                            >
                              {reasoningLabels[row.reasoningEffort] ??
                                row.reasoningEffort}
                            </Badge>
                          )}
                        </Group>
                        <Group
                          justify="space-between"
                          wrap="nowrap"
                          gap={4}
                          className={styles.requestFooter}
                        >
                          {row.accountID ? (
                            <Anchor
                              component={Link}
                              to={`/?account=${encodeURIComponent(row.accountID)}`}
                              size="xs"
                              truncate
                              title={account ?? undefined}
                            >
                              {account}
                            </Anchor>
                          ) : (
                            <Text size="xs" c="dimmed">
                              账号未知
                            </Text>
                          )}
                          <Badge
                            size="xs"
                            variant="light"
                            className={styles.requestElapsed}
                            color={
                              row.hasFirstEvent == null
                                ? "gray"
                                : row.hasFirstEvent
                                  ? "teal"
                                  : "orange"
                            }
                            title="首事件是首个上游协议事件，不代表输出完成"
                          >
                            {row.hasFirstEvent == null
                              ? "未观测"
                              : row.hasFirstEvent
                                ? "响应中"
                                : "等待响应"}
                          </Badge>
                        </Group>
                      </Paper>
                    );
                  })}
              </div>
            )}
          </Paper>
          <KeyResults query={keySummary} />
        </Stack>
        {sidebar && (
          <aside className={styles.sidebar} aria-label="订阅额度与系统状态">
            {sidebar(
              <OutputRateTrend
                rates={live?.settledOutputDays}
                buckets={daily.data?.buckets ?? []}
                offsetMinutes={daily.data?.businessDay.offsetMinutes}
              />,
            )}
            {connectionNotice}
          </aside>
        )}
      </div>
      {!sidebar && connectionNotice}
    </Stack>
  );
}
