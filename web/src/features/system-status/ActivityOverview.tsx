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
import { ErrorState, StatusBadge } from "../../shared/ui/States";
import styles from "./overview.module.css";
import { PageHeader } from "../../shared/ui/PageHeader";
import { OverviewStats } from "./OverviewStats";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { localTime, modes } from "../../shared/presentation";
import type { CapacityMetric } from "./overview-format";
import { KeyResults } from "./KeyResults";
import { fetchDaily, fetchInFlight, fetchKeySummary } from "./round2-api";
import { useOverviewRefresh } from "./useOverviewRefresh";
function UpdatedAgo({ updated }: { updated: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!document.hidden) setNow(Date.now());
    }, 1000);
    return () => window.clearInterval(timer);
  }, []);
  return (
    <Text size="xs">
      {updated
        ? `${Math.max(0, Math.floor((now - updated) / 1000))} 秒前更新`
        : "尚未更新"}
    </Text>
  );
}
export function ActivityOverview({
  refresh,
  extraQueries = [],
  sidebar,
  attention,
  accounts = [],
  capacities,
}: {
  refresh?: ReturnType<typeof useOverviewRefresh>;
  extraQueries?: {
    source: string;
    isError: boolean;
    dataUpdatedAt: number;
    isFetching: boolean;
    refetch: () => Promise<unknown>;
  }[];
  sidebar?: ReactNode;
  attention?: ReactNode;
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
    refetchOnWindowFocus: true,
    staleTime: 15000,
  };
  const daily = useQuery({
    queryKey: ["overview", "daily"],
    queryFn: ({ signal }) => fetchDaily(signal),
    ...options,
  });
  const flight = useQuery({
    queryKey: ["overview", "in-flight"],
    queryFn: ({ signal }) => fetchInFlight(signal),
    ...options,
  });
  // All overview snapshots share the same pause and refresh cadence.
  const keySummary = useQuery({
    queryKey: ["overview", "keys"],
    queryFn: ({ signal }) => fetchKeySummary(signal),
    ...options,
  });
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

  return (
    <Stack aria-label="请求即时概览">
      <div className={styles.header}>
        <PageHeader
          title="今日运营概览"
          description="UTC 当日 · 费用为估算，非账单"
          actions={
            <Group>
              <Switch
                label="自动刷新（15 秒）"
                checked={control.automatic}
                onChange={(e) => control.setAutomatic(e.currentTarget.checked)}
              />
              <UpdatedAgo updated={updated} />
              <Button
                size="xs"
                variant="default"
                disabled={allQueries.some((q) => q.isFetching)}
                onClick={() => {
                  for (const q of allQueries) void q.refetch();
                }}
              >
                刷新请求概览
              </Button>
            </Group>
          }
        />
      </div>
      {attention}
      {allQueries.some((q) => q.isError) && (
        <ErrorState
          retry={() => {
            for (const q of allQueries) void q.refetch();
          }}
        >
          概览读取失败：
          {allQueries
            .filter((q) => q.isError)
            .map(
              (q) =>
                `${q.source}${q.dataUpdatedAt ? `（保留上次成功快照 ${localTime(q.dataUpdatedAt / 1000)}）` : "（尚无成功数据）"}`,
            )
            .join("、")}
          。缺失值未记为零，请重试。
        </ErrorState>
      )}
      {daily.isError && !daily.data ? (
        <Text size="sm" c="dimmed">
          运营指标读取失败，请重试。
        </Text>
      ) : (
        <OverviewStats
          buckets={daily.data ?? []}
          loading={daily.isPending}
          capacities={capacities}
        />
      )}
      <div className={sidebar ? styles.content : undefined}>
        <Stack className={styles.main}>
          <KeyResults query={keySummary} />
          <Paper withBorder p="md">
            <Group justify="space-between" mb="xs">
              <Title order={3} size="h4">
                进行中请求
              </Title>
            </Group>
            {flight.isError && !flight.data ? (
              <Text size="sm" c="dimmed">
                进行中请求读取失败。请重试。
              </Text>
            ) : flight.data?.length === 0 ? (
              <Text size="sm" c="dimmed">
                当前没有进行中的请求。
              </Text>
            ) : (
              <DataTable
                rows={flight.data ?? []}
                rowKey={(row) => row.id}
                retry={() => void flight.refetch()}
                loading={flight.isPending}
                empty="当前没有进行中的请求。"
                columns={[
                  {
                    id: "principal",
                    title: "Key",
                    width: "22%",
                    render: (row) => <KeyName {...row} />,
                  },
                  {
                    id: "model",
                    title: "模型 / 模式",
                    width: "20%",
                    render: (row) => (
                      <Stack gap={2}>
                        <Text size="sm">{row.model ?? "模型未记录"}</Text>
                        <Text size="xs" c="dimmed">
                          {modes[row.mode] ?? "其他模式"}
                        </Text>
                      </Stack>
                    ),
                  },
                  {
                    id: "reasoning",
                    title: "推理强度",
                    width: "12%",
                    render: (row) => (
                      <Text
                        size="sm"
                        title={
                          row.reasoningEffort
                            ? "请求中记录的推理强度，非提供者实际执行强度证明。"
                            : row.requestMetadataRecorded
                              ? "请求未显式指定推理强度，不推断实际生效值。"
                              : "该执行未记录请求参数。"
                        }
                      >
                        {row.reasoningEffort ??
                          (row.requestMetadataRecorded ? "未指定" : "未记录")}
                      </Text>
                    ),
                  },
                  {
                    id: "account",
                    title: "订阅账号",
                    width: "22%",
                    render: (row) =>
                      row.accountID ? (
                        <Anchor
                          component={Link}
                          to={`/?account=${encodeURIComponent(row.accountID)}`}
                          size="sm"
                        >
                          {accountName(
                            row.accountID,
                            accounts,
                            row.accountDisplayName,
                          )}
                        </Anchor>
                      ) : (
                        accountName(null, accounts)
                      ),
                  },
                  {
                    id: "elapsed",
                    title: "运行时长",
                    width: "12%",
                    render: (row) =>
                      row.elapsedSeconds == null
                        ? "耗时不可用"
                        : `已持续 ${Math.floor(row.elapsedSeconds)} 秒`,
                  },
                  {
                    id: "event",
                    title: "首事件",
                    width: "12%",
                    render: (row) => (
                      <span
                        title={
                          row.hasFirstEvent == null
                            ? "该执行没有首事件观测，不能据此判断是否已收到上游事件。"
                            : "首事件是首个上游协议事件，不代表输出完成。"
                        }
                        tabIndex={0}
                      >
                        <StatusBadge
                          color={row.hasFirstEvent ? "green" : "gray"}
                        >
                          {row.hasFirstEvent == null
                            ? "未观测"
                            : row.hasFirstEvent
                              ? "已收到首事件"
                              : "等待首事件"}
                        </StatusBadge>
                      </span>
                    ),
                  },
                ]}
              />
            )}
          </Paper>
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
