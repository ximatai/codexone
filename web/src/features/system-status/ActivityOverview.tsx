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
  Tooltip,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router";
import { DataTable } from "../../shared/ui/DataTable";
import { ErrorState, StatusBadge } from "../../shared/ui/States";
import styles from "./overview.module.css";
import { PageHeader } from "../../shared/ui/PageHeader";
import { duration } from "../usage/format";
import { OverviewStats } from "./OverviewStats";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { localTime, outcomes, modes } from "../../shared/presentation";
import { UsageDetail } from "../usage/UsageDetail";
import type { UsageReport } from "../usage/api";
import { fetchDaily, fetchInFlight, fetchRecent } from "./round2-api";
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
}: {
  refresh?: ReturnType<typeof useOverviewRefresh>;
  extraQueries?: {
    dataUpdatedAt: number;
    isFetching: boolean;
    refetch: () => Promise<unknown>;
  }[];
  sidebar?: ReactNode;
  attention?: ReactNode;
  accounts?: readonly AccountName[];
}) {
  const owner = useManagementSession();
  const localRefresh = useOverviewRefresh();
  const control = refresh ?? localRefresh;
  const [detail, setDetail] = useState<UsageReport["rows"][number] | null>(
    null,
  );
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
  const recent = useQuery({
    queryKey: ["overview", "recent"],
    queryFn: ({ signal }) => fetchRecent(signal),
    ...options,
  });
  const queries = [daily, flight, recent];
  const allQueries = [...queries, ...extraQueries];
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
      {queries.some((q) => q.isError) && (
        <ErrorState
          retry={() => {
            for (const q of allQueries) void q.refetch();
          }}
        >
          部分请求概览读取失败，请刷新重试；保留的快照可能已过时，缺失值未记为零。
        </ErrorState>
      )}
      <Tooltip
        events={{ hover: true, focus: true, touch: true }}
        label="近 7 天 · UTC；今日未结束，与昨日完整日比较。Token 为已观测输入与输出之和，缓存包含在输入中；缺失用量保持不可用，Token 与费用为已观测下界。"
      >
        <Text size="xs" c="dimmed" w="fit-content" tabIndex={0}>
          KPI 统计口径 ⓘ
        </Text>
      </Tooltip>
      {daily.isError ? (
        <ErrorState retry={() => void daily.refetch()}>
          运营指标读取失败，请重试。
        </ErrorState>
      ) : (
        <OverviewStats buckets={daily.data ?? []} loading={daily.isPending} />
      )}
      <div className={sidebar ? styles.content : undefined}>
        <Stack className={styles.main}>
          <Paper withBorder p="md">
            <Group justify="space-between" mb="xs">
              <Title order={3} size="h4">
                进行中请求
              </Title>
            </Group>
            <Text size="xs" c="dimmed" mb="sm">
              最多显示 200 条；随自动刷新更新。
            </Text>
            <DataTable
              rows={flight.data ?? []}
              rowKey={(row) => row.id}
              retry={() => void flight.refetch()}
              loading={flight.isPending}
              error={
                flight.isError
                  ? `进行中请求读取失败。${flight.dataUpdatedAt ? `上次成功读取：${localTime(flight.dataUpdatedAt / 1000)}` : "请重试。"}`
                  : undefined
              }
              empty="当前没有进行中的请求。"
              columns={[
                {
                  id: "principal",
                  title: "主体 / 模型",
                  render: (row) => (
                    <Stack gap={2}>
                      <Text size="sm">
                        {<KeyName {...row} />} · {row.model ?? "模型未记录"}
                      </Text>
                      <Text size="xs" c="dimmed">
                        {modes[row.mode] ?? "其他模式"} ·{" "}
                        {accountName(
                          row.accountID,
                          accounts,
                          row.accountDisplayName,
                        )}
                      </Text>
                    </Stack>
                  ),
                },
                {
                  id: "elapsed",
                  title: "运行时长",
                  render: (row) =>
                    row.elapsedSeconds == null
                      ? "耗时不可用"
                      : `已持续 ${Math.floor(row.elapsedSeconds)} 秒`,
                },
                {
                  id: "event",
                  title: "最新状态",
                  render: (row) => (
                    <StatusBadge color={row.hasFirstEvent ? "green" : "gray"}>
                      {row.hasFirstEvent == null
                        ? "首事件状态不可用"
                        : row.hasFirstEvent
                          ? "已收到首事件"
                          : "等待首事件"}
                    </StatusBadge>
                  ),
                },
              ]}
            />
          </Paper>
          <Paper withBorder p="md">
            <Group justify="space-between" mb="xs">
              <Title order={3} size="h4">
                最近请求
              </Title>
              <Anchor component={Link} to="/usage">
                查看全部用量
              </Anchor>
            </Group>
            <Text size="xs" c="dimmed" mb="sm">
              最近 31 天内的 20
              条已结束请求，随自动刷新更新；待核对结果不代表成功。
            </Text>
            {recent.data?.truncated && (
              <Text c="orange" size="xs">
                扫描已达上限，可到用量页查询更早请求。
              </Text>
            )}
            <DataTable
              onRowClick={setDetail}
              rows={recent.data?.rows ?? []}
              rowKey={(row) => row.id}
              retry={() => void recent.refetch()}
              loading={recent.isPending}
              error={
                recent.isError
                  ? `最近请求读取失败。${recent.dataUpdatedAt ? `上次成功读取：${localTime(recent.dataUpdatedAt / 1000)}` : "请重试。"}`
                  : undefined
              }
              empty="暂无已结束的请求。"
              columns={[
                {
                  id: "time",
                  title: "开始时间（本地）",
                  width: "25%",
                  nowrap: true,
                  render: (row) => localTime(row.atUnixSeconds),
                },
                {
                  id: "principal",
                  title: "Key / 模型",
                  render: (row) => (
                    <span>
                      <KeyName {...row} /> · {row.model ?? "未记录"}
                    </span>
                  ),
                },
                {
                  id: "outcome",
                  title: "结果",
                  width: "13%",
                  render: (row) => (
                    <StatusBadge
                      color={
                        row.outcome === "succeeded"
                          ? "green"
                          : row.outcome === "failed"
                            ? "red"
                            : "gray"
                      }
                    >
                      {row.outcome
                        ? (outcomes[row.outcome] ?? "待核对")
                        : "待核对"}
                    </StatusBadge>
                  ),
                },
                {
                  id: "timing",
                  title: "首事件 / 总耗时",
                  render: (row) =>
                    `${duration(row.firstEventMilliseconds)} / ${duration(row.totalMilliseconds)}`,
                },
                {
                  id: "open",
                  title: "",
                  width: "4%",
                  render: () => <span aria-hidden="true">›</span>,
                },
              ]}
            />
          </Paper>
        </Stack>
        {sidebar && (
          <aside className={styles.sidebar} aria-label="订阅额度与系统状态">
            {sidebar}
          </aside>
        )}
      </div>
      <UsageDetail
        accounts={accounts}
        detail={detail}
        onClose={() => setDetail(null)}
      />
    </Stack>
  );
}
