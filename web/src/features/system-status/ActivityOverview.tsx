import { useQuery } from "@tanstack/react-query";
import {
  Anchor,
  Button,
  Group,
  Paper,
  Stack,
  Switch,
  Skeleton,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router";
import { DataTable } from "../../shared/ui/DataTable";
import { ErrorState, StatusBadge } from "../../shared/ui/States";
import styles from "./overview.module.css";
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
  refreshOverview,
  sidebar,
}: {
  refreshOverview: () => Promise<unknown>;
  sidebar?: ReactNode;
}) {
  const owner = useManagementSession();
  const refresh = useOverviewRefresh();
  const [detail, setDetail] = useState<UsageReport["rows"][number] | null>(
    null,
  );
  const options = {
    enabled: !!owner.session,
    refetchInterval: refresh.interval,
    // Returning to the tab refetches only snapshots older than one refresh period.
    refetchOnWindowFocus: true,
    staleTime: 15000,
    retry: false as const,
  };
  const daily = useQuery({
    queryKey: ["overview", "daily"],
    queryFn: async ({ signal }) => {
      await refreshOverview();
      return fetchDaily(signal);
    },
    ...options,
  });
  const flight = useQuery({
    queryKey: ["overview", "in-flight"],
    queryFn: ({ signal }) => fetchInFlight(signal),
    ...options,
  });
  // Recent rows may page through the usage window, so they refresh less often.
  const recent = useQuery({
    queryKey: ["overview", "recent"],
    queryFn: ({ signal }) => fetchRecent(signal),
    ...options,
    refetchInterval: refresh.interval && 60000,
    staleTime: 60000,
  });
  const queries = [daily, flight, recent];
  const unauthorized = queries.some(
    (q) => q.error instanceof ManagementError && q.error.status === 401,
  );
  useEffect(() => {
    if (unauthorized) owner.invalidate();
  }, [unauthorized, owner]);
  if (!owner.session) return null;
  const updated = queries.every((q) => q.dataUpdatedAt > 0)
    ? Math.min(...queries.map((q) => q.dataUpdatedAt))
    : 0;

  return (
    <Stack aria-label="请求即时概览">
      <Group justify="space-between">
        <Text size="sm" c="dimmed">
          近 7 天 · UTC · 今日未结束，与昨日完整日比较；Token
          为已观测输入与输出之和，缓存包含在输入中。
        </Text>
        <Group>
          <Switch
            label="自动刷新（15 秒）"
            checked={refresh.automatic}
            onChange={(e) => refresh.setAutomatic(e.currentTarget.checked)}
          />
          <UpdatedAgo updated={updated} />
          <Button
            size="xs"
            variant="default"
            disabled={queries.some((q) => q.isFetching)}
            onClick={() => {
              for (const q of queries) void q.refetch();
            }}
          >
            刷新请求概览
          </Button>
        </Group>
      </Group>
      {queries.some((q) => q.isPending) && (
        <Stack role="status" aria-label="正在读取请求概览…">
          <Skeleton h={84} />
          <Text size="sm">正在读取请求概览…</Text>
        </Stack>
      )}
      {queries.some((q) => q.isError) && (
        <ErrorState
          retry={() => {
            for (const q of queries) void q.refetch();
          }}
        >
          部分请求概览读取失败，请刷新重试；保留的快照可能已过时，缺失值未记为零。
        </ErrorState>
      )}
      <OverviewStats buckets={daily.data ?? []} />
      <div className={sidebar ? styles.content : undefined}>
        <Stack className={styles.main}>
          <Paper withBorder p="md">
            <Group justify="space-between" mb="xs">
              <Title order={3} size="h4">
                进行中请求
              </Title>
              <Anchor component={Link} to="/usage">
                查看全部用量
              </Anchor>
            </Group>
            <Text size="xs" c="dimmed" mb="sm">
              最多显示 200 条；随自动刷新更新。
            </Text>
            <DataTable
              rows={flight.data ?? []}
              rowKey={(row) => row.id}
              retry={() => void flight.refetch()}
              loading={flight.isPending}
              empty="当前没有进行中的请求。"
              columns={[
                {
                  id: "principal",
                  title: "主体 / 模型",
                  render: (row) => (
                    <Stack gap={2}>
                      <Text size="sm">
                        {row.principal ?? "主体未记录"} ·{" "}
                        {row.model ?? "模型未记录"}
                      </Text>
                      <Text size="xs" c="dimmed">
                        {modes[row.mode] ?? "其他模式"} ·{" "}
                        {row.accountDisplayName ??
                          row.accountID ??
                          "账号未记录"}
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
              最近 31 天内的 20 条已结束请求，每分钟刷新；待核对结果不代表成功。
            </Text>
            {recent.data?.truncated && (
              <Text c="orange" size="xs">
                扫描已达上限，可到用量页查询更早请求。
              </Text>
            )}
            <DataTable
              rows={recent.data?.rows ?? []}
              rowKey={(row) => row.id}
              retry={() => void recent.refetch()}
              loading={recent.isPending}
              empty="暂无已结束的请求。"
              columns={[
                {
                  id: "time",
                  title: "开始时间（本地）",
                  render: (row) => localTime(row.atUnixSeconds),
                },
                {
                  id: "principal",
                  title: "Key / 模型",
                  render: (row) =>
                    `${row.principal ?? "主体未记录"} · ${row.model ?? "未记录"}`,
                },
                {
                  id: "outcome",
                  title: "结果",
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
                    `${row.firstEventMilliseconds == null ? "不可用" : row.firstEventMilliseconds + " ms"} / ${row.totalMilliseconds == null ? "不可用" : row.totalMilliseconds + " ms"}`,
                },
                {
                  id: "detail",
                  title: "详情",
                  render: (row) => (
                    <Button
                      variant="subtle"
                      size="xs"
                      onClick={() => setDetail(row)}
                    >
                      查看详情
                    </Button>
                  ),
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
      <UsageDetail detail={detail} onClose={() => setDetail(null)} />
    </Stack>
  );
}
