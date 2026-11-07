import { overviewQuery } from "./overview-source";
import type { useOverviewLive } from "./useOverviewLive";
import { KeyName } from "../../shared/KeyName";
import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
import { useQuery } from "@tanstack/react-query";
import {
  Anchor,
  Button,
  Group,
  Paper,
  Stack,
  Switch,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router";
import { DataTable } from "../../shared/ui/DataTable";
import { ErrorState } from "../../shared/ui/States";
import styles from "./overview.module.css";
import { PageHeader } from "../../shared/ui/PageHeader";
import { OverviewStats } from "./OverviewStats";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { localTime } from "../../shared/presentation";
import type { CapacityMetric } from "./overview-format";
import { KeyResults } from "./KeyResults";
import { fetchDaily, fetchInFlight, fetchKeySummary } from "./round2-api";
import { useOverviewRefresh } from "./useOverviewRefresh";
const sourceLabels: Record<string, string> = {
  system: "服务状态",
  inFlight: "进行中请求",
  daily: "请求统计",
  keys: "今日 Key 汇总",
  accounts: "订阅账号",
  storage: "存储与备份",
  attention: "待处理提醒",
  headroom: "资源余量",
};
function UpdatedAgo({ updated }: { updated: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!document.hidden) setNow(Date.now());
    }, 1000);
    return () => window.clearInterval(timer);
  }, []);
  return (
    <Text size="xs" className={styles.updatedAgo}>
      {updated
        ? `${Math.max(0, Math.floor((now - updated) / 1000))} 秒前更新`
        : "尚未更新"}
    </Text>
  );
}
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
  capacities,
  live,
  summary,
}: {
  summary?: ReactNode;
  live?: ReturnType<typeof useOverviewLive>;
  refresh?: ReturnType<typeof useOverviewRefresh>;
  extraQueries?: {
    source: string;
    isError: boolean;
    dataUpdatedAt: number;
    isFetching: boolean;
    refetch: () => Promise<unknown>;
  }[];
  sidebar?: ReactNode;
  accounts?: readonly AccountName[];
  capacities?: CapacityMetric[];
}) {
  const owner = useManagementSession();
  const localRefresh = useOverviewRefresh();
  const control = refresh ?? localRefresh;
  const options = {
    enabled: !!owner.session,
    refetchInterval: control.interval,
    // Returning to the tab refetches only snapshots older than one refresh period.
    refetchOnWindowFocus: control.active && live?.mode !== "live",
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
  const updated = allQueries.every((q) => q.dataUpdatedAt > 0)
    ? Math.min(...allQueries.map((q) => q.dataUpdatedAt))
    : 0;
  const failedSources = allQueries.filter((query) => query.isError);
  const readFailure = failedSources.length
    ? `概览读取失败：${failedSources
        .map(
          (query) =>
            `${query.source}${query.dataUpdatedAt ? `（保留上次成功快照 ${localTime(query.dataUpdatedAt / 1000)}）` : "（尚无成功数据）"}`,
        )
        .join("、")}。缺失值未记为零，请重试。`
    : "";
  const retrySources = () => {
    for (const query of allQueries) void query.refetch();
  };

  return (
    <Stack aria-label="请求即时概览">
      <div className={styles.header}>
        <PageHeader
          title="今日运营概览"
          description={`${daily.data?.timezone ?? "业务日"} 当日 · 费用为估算，非账单`}
          actions={
            <Group>
              <Switch
                label={live?.mode === "live" ? "实时观察" : "自动刷新（15 秒）"}
                checked={control.automatic}
                onChange={(e) => control.setAutomatic(e.currentTarget.checked)}
              />
              <UpdatedAgo updated={updated} />
              <Button
                size="xs"
                variant="default"
                disabled={allQueries.some((q) => q.isFetching)}
                onClick={() => {
                  if (control.manualRefresh) control.manualRefresh();
                  else for (const q of allQueries) void q.refetch();
                }}
              >
                刷新请求概览
              </Button>
            </Group>
          }
        />
      </div>
      {!control.automatic && !live && (
        <Text size="xs" c="dimmed">
          自动观察已暂停，以下为上次快照。
        </Text>
      )}
      {live && (
        <div
          aria-label="概览连接状态"
          data-live-failure={live.failure || undefined}
        >
          <Text size="xs">
            {
              {
                live: "实时连接",
                connecting: "连接中 · HTTP 轮询",
                polling: "轮询模式（15 秒）· 活动观察中断",
                paused: "观察已暂停",
              }[live.mode]
            }
          </Text>
          <details>
            <summary
              className={styles.sourceSummary}
              title={readFailure || undefined}
            >
              {readFailure ? (
                <span role="alert">{readFailure}</span>
              ) : (
                <>
                  各源更新时间
                  {live.stale.length
                    ? ` · ${live.stale.length} 个来源已陈旧`
                    : ""}
                </>
              )}
            </summary>
            <div className={styles.sourceDetails}>
              {readFailure && (
                <>
                  <Text size="sm" c="red">
                    {readFailure}
                  </Text>
                  <Button variant="subtle" size="xs" onClick={retrySources}>
                    重试
                  </Button>
                </>
              )}
              {Object.entries(live.sources).map(([name, source]) => (
                <Text size="xs" key={name}>
                  {sourceLabels[name] ?? "概览来源"} ·{" "}
                  {source.lastSuccessAt == null
                    ? "尚无成功数据"
                    : localTime(source.lastSuccessAt)}{" "}
                  ·{" "}
                  {live.stale.some(([key]) => key === name)
                    ? "已陈旧"
                    : "已更新"}
                </Text>
              ))}
            </div>
          </details>
        </div>
      )}
      {summary}
      {!live && failedSources.length > 0 && (
        <ErrorState retry={retrySources}>{readFailure}</ErrorState>
      )}
      <div className={sidebar ? styles.content : undefined}>
        <Stack className={styles.main}>
          {daily.isError && !daily.data ? (
            <Text size="sm" c="dimmed">
              运营指标读取失败，请重试。
            </Text>
          ) : (
            <OverviewStats
              buckets={daily.data?.buckets ?? []}
              loading={daily.isPending}
              capacities={capacities}
            />
          )}
          <Paper withBorder p="md">
            <Title order={3} size="h4" mb="xs">
              进行中请求{flight.data ? ` · ${flight.data.length}` : ""}
            </Title>
            {flight.isError && !flight.data ? (
              <Text size="sm" c="dimmed">
                进行中请求读取失败。请重试。
              </Text>
            ) : flight.isPending || !flight.data?.length ? (
              <Text size="sm" c="dimmed" className={styles.requestEmpty}>
                {flight.isPending ? "读取中…" : "当前没有进行中的请求。"}
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
                  .map((row) => (
                    <Paper
                      key={row.id}
                      withBorder
                      p="xs"
                      className={styles.requestCard}
                    >
                      <Group justify="space-between" wrap="nowrap" gap={4}>
                        <KeyName {...row} />
                        <Text size="xs" className={styles.requestElapsed}>
                          <Elapsed
                            seconds={row.elapsedSeconds}
                            sampledAt={flight.dataUpdatedAt}
                            running={
                              control.active &&
                              !flight.isError &&
                              (!live ||
                                !live.stale.some(
                                  ([source]) => source === "inFlight",
                                ))
                            }
                          />
                        </Text>
                      </Group>
                      <Group justify="space-between" wrap="nowrap" gap={4}>
                        <Text size="xs" className="wrap-anywhere">
                          {row.model ?? "模型未知"}
                        </Text>
                        <Text
                          size="xs"
                          className={styles.requestElapsed}
                          c={row.hasFirstEvent ? "teal.8" : "dimmed"}
                          title="首事件是首个上游协议事件，不代表输出完成"
                        >
                          {row.hasFirstEvent == null
                            ? "未观测"
                            : row.hasFirstEvent
                              ? "首事件已到"
                              : "待首事件"}
                        </Text>
                      </Group>
                      <Group justify="space-between" wrap="nowrap" gap={4}>
                        {row.accountID ? (
                          <Anchor
                            component={Link}
                            to={`/?account=${encodeURIComponent(row.accountID)}`}
                            size="xs"
                            className="wrap-anywhere"
                          >
                            {accountName(
                              row.accountID,
                              accounts,
                              row.accountDisplayName,
                            )}
                          </Anchor>
                        ) : (
                          <Text size="xs" c="dimmed">
                            账号未知
                          </Text>
                        )}
                        {row.reasoningEffort && (
                          <Text size="xs" title="请求指定的推理强度">
                            {(
                              {
                                minimal: "最低",
                                low: "低",
                                medium: "中",
                                high: "高",
                                xhigh: "极高",
                              } as Record<string, string>
                            )[row.reasoningEffort] ?? row.reasoningEffort}
                          </Text>
                        )}
                      </Group>
                    </Paper>
                  ))}
              </div>
            )}
          </Paper>
          <KeyResults query={keySummary} />
          {live?.mode === "live" && (
            <Paper withBorder p="md">
              <Title order={3} size="h4">
                持续连接
              </Title>
              <Text size="xs" c="dimmed">
                仅统计数据 WebSocket，按 Key 汇总；HTTP 调用请查看请求列表。
              </Text>
              <DataTable
                animate
                rows={live.clients}
                rowKey={(row) => row.keyID}
                retry={() => {}}
                empty="当前没有持续连接的客户端。"
                columns={[
                  {
                    id: "key",
                    title: "Key",
                    render: (row) => {
                      const key = keySummary.data?.keys.find(
                        (key) => key.keyID === row.keyID,
                      );
                      return (
                        <Anchor
                          component={Link}
                          to={`/keys?target=${encodeURIComponent(row.keyID)}`}
                        >
                          <KeyName
                            displayName={row.displayName ?? key?.displayName}
                            principal={key?.principal ?? row.keyID.slice(-8)}
                          />
                        </Anchor>
                      );
                    },
                  },
                  { id: "count", title: "连接数", render: (row) => row.count },
                  {
                    id: "since",
                    title: "最早连接",
                    render: (row) => localTime(row.connectedAtUnixSeconds),
                  },
                ]}
              />
            </Paper>
          )}
          {!!live?.overflow && (
            <Text size="xs">
              另有 {live.overflow} 条活动未在缓冲中保留，请在用量页查看历史。
            </Text>
          )}
        </Stack>
        {sidebar && (
          <aside className={styles.sidebar} aria-label="订阅额度与系统状态">
            {sidebar}
          </aside>
        )}
      </div>
    </Stack>
  );
}
