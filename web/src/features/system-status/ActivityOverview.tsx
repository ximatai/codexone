import { useQuery } from "@tanstack/react-query";
import {
  Alert,
  Button,
  Group,
  Paper,
  Stack,
  Switch,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState } from "react";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import {
  failures,
  localTime,
  money,
  outcomes,
  modes,
} from "../../shared/presentation";
import { UsageDetail } from "../usage/UsageDetail";
import type { UsageReport } from "../usage/api";
import {
  change,
  fetchDaily,
  fetchInFlight,
  fetchRecent,
  pointChange,
  tokenTotal,
  trendPoints,
} from "./round2-api";
import { useOverviewRefresh } from "./useOverviewRefresh";
function Sparkline({
  values,
  label,
}: {
  values: (number | null)[];
  label: string;
}) {
  const points = trendPoints(values);
  const segments: string[][] = [[]];
  for (const point of points) {
    if (point === null) segments.push([]);
    else segments.at(-1)!.push(point);
  }
  return (
    <svg
      role="img"
      aria-label={`${label}近 7 天：${values.map((v) => (v === null ? "不可用" : Number(v.toFixed(1)))).join("、")}`}
      viewBox="-2 0 104 38"
      preserveAspectRatio="none"
      width="100%"
      height="46"
      style={{ color: "var(--mantine-primary-color-filled)" }}
    >
      {segments.map((segment, index) => (
        <polyline
          key={index}
          points={segment.join(" ")}
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
        />
      ))}
    </svg>
  );
}
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
}: {
  refreshOverview: () => Promise<unknown>;
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
    queryKey: ["overview-daily"],
    queryFn: async ({ signal }) => {
      await refreshOverview();
      return fetchDaily(signal);
    },
    ...options,
  });
  const flight = useQuery({
    queryKey: ["overview-in-flight"],
    queryFn: ({ signal }) => fetchInFlight(signal),
    ...options,
  });
  // Recent rows may page through the usage window, so they refresh less often.
  const recent = useQuery({
    queryKey: ["overview-recent"],
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
  const buckets = daily.data ?? [];
  const today = buckets.at(-1),
    yesterday = buckets.at(-2);
  const errorRate = (bucket: typeof today) =>
    bucket
      ? bucket.requests
        ? (bucket.failed / bucket.requests) * 100
        : null
      : null;
  const mainFailure = today
    ? Object.entries(today.failures)
        .filter(([kind, count]) => count > 0 && kind !== "client_cancelled")
        .sort((a, b) => b[1] - a[1])[0]
    : undefined;
  const failureCount = today
    ? Object.entries(today.failures)
        .filter(([kind]) => kind !== "client_cancelled")
        .reduce((a, [, b]) => a + b, 0)
    : 0;
  const updated = queries.every((q) => q.dataUpdatedAt > 0)
    ? Math.min(...queries.map((q) => q.dataUpdatedAt))
    : 0;
  const cards = [
    {
      label: "今日请求",
      value: today?.requests.toLocaleString() ?? "—",
      values: buckets.map((b) => b.requests),
      delta: change(today?.requests, yesterday?.requests),
      note: "按准入时间统计",
    },
    {
      label: "Token",
      value:
        today && tokenTotal(today) !== null
          ? (
              BigInt(today.metrics.inputTokens!) +
              BigInt(today.metrics.outputTokens!)
            ).toLocaleString()
          : "不可用",
      values: buckets.map(tokenTotal),
      delta: change(
        today ? tokenTotal(today) : null,
        yesterday ? tokenTotal(yesterday) : null,
      ),
      note:
        today?.metrics.cachedTokens != null &&
        today.metrics.inputTokens != null &&
        BigInt(today.metrics.inputTokens) > 0n
          ? `输入缓存占比 ${((Number(today.metrics.cachedTokens) / Number(today.metrics.inputTokens)) * 100).toFixed(1)}%`
          : "输入缓存占比不可用",
    },
    {
      label: "费用",
      value: money(today?.metrics.estimatedMicros),
      values: buckets.map((b) =>
        b.metrics.estimatedMicros === null
          ? null
          : Number(b.metrics.estimatedMicros) / 1000000,
      ),
      delta: change(
        today?.metrics.estimatedMicros == null
          ? null
          : Number(today.metrics.estimatedMicros),
        yesterday?.metrics.estimatedMicros == null
          ? null
          : Number(yesterday.metrics.estimatedMicros),
      ),
      note: "估算，非账单",
    },
    {
      label: "错误率",
      value:
        errorRate(today) === null ? "—" : `${errorRate(today)!.toFixed(1)}%`,
      values: buckets.map(errorRate),
      delta: pointChange(errorRate(today), errorRate(yesterday)),
      note: mainFailure
        ? `主要异常：${failures[mainFailure[0]] ?? "其他异常"}（${((mainFailure[1] / failureCount) * 100).toFixed(0)}%）`
        : today
          ? today.cancelled
            ? `暂无失败类别 · 客户端取消 ${today.cancelled}`
            : "暂无失败类别"
          : "失败类别不可用",
    },
  ];
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
        <Text role="status">正在读取请求概览…</Text>
      )}
      {queries.some((q) => q.isError) && (
        <Alert color="yellow" role="alert">
          部分请求概览读取失败，请刷新重试；保留的快照可能已过时，缺失值未记为零。
        </Alert>
      )}
      <div className="responsive-grid responsive-grid-4">
        {cards.map((card) => (
          <Paper key={card.label} withBorder p="md">
            <Text size="sm">{card.label}</Text>
            <Title order={3}>{card.value}</Title>
            <Sparkline label={card.label} values={card.values} />
            <Text size="xs">{card.delta}</Text>
            <Text size="xs" c="dimmed">
              {card.note}
            </Text>
          </Paper>
        ))}
      </div>
      <Paper withBorder p="md">
        <Title order={3} size="h4">
          进行中请求
        </Title>
        <Text size="xs" c="dimmed">
          最多显示 200 条；随自动刷新更新。
        </Text>
        {flight.data?.length === 0 && (
          <Text c="dimmed">当前没有进行中的请求。</Text>
        )}
        <Stack gap="xs" mt="sm">
          {flight.data?.map((row) => (
            <Group
              key={row.id}
              justify="space-between"
              className="wrap-anywhere"
            >
              <Text size="sm">
                {row.principal ?? row.keyID} · {row.model ?? "模型未记录"} ·{" "}
                {modes[row.mode] ?? "其他模式"} ·{" "}
                {row.accountDisplayName ?? row.accountID ?? "账号未记录"}
              </Text>
              <Text size="xs">
                {row.elapsedSeconds == null
                  ? "耗时不可用"
                  : `已持续 ${Math.floor(row.elapsedSeconds)} 秒`}{" "}
                ·{" "}
                {row.hasFirstEvent == null
                  ? "首事件状态不可用"
                  : row.hasFirstEvent
                    ? "已收到首事件"
                    : "等待首事件"}
              </Text>
            </Group>
          ))}
        </Stack>
      </Paper>
      <Paper withBorder p="md">
        <Title order={3} size="h4">
          最近请求
        </Title>
        <Text size="xs" c="dimmed">
          最近 31 天内的 20 条已结束请求，每分钟刷新；待核对结果不代表成功。
        </Text>
        {recent.data?.truncated && (
          <Text c="orange" size="xs">
            扫描已达上限，可到用量页查询更早请求。
          </Text>
        )}
        {recent.data?.rows.length === 0 && (
          <Text c="dimmed">暂无已结束的请求。</Text>
        )}
        <div className="responsive-table">
          <Table>
            <Table.Thead>
              <Table.Tr>
                <Table.Th>开始时间（本地）</Table.Th>
                <Table.Th>Key / 模型</Table.Th>
                <Table.Th>结果</Table.Th>
                <Table.Th>详情</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {recent.data?.rows.map((row) => (
                <Table.Tr key={row.id}>
                  <Table.Td data-label="开始时间">
                    {localTime(row.atUnixSeconds)}
                  </Table.Td>
                  <Table.Td data-label="Key / 模型">
                    {row.principal ?? row.keyID} · {row.model ?? "未记录"}
                  </Table.Td>
                  <Table.Td data-label="结果">
                    {row.outcome
                      ? (outcomes[row.outcome] ?? "待核对")
                      : "待核对"}
                  </Table.Td>
                  <Table.Td data-label="详情">
                    <Button
                      variant="subtle"
                      size="xs"
                      onClick={() => setDetail(row)}
                    >
                      查看详情
                    </Button>
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </div>
      </Paper>
      <UsageDetail detail={detail} onClose={() => setDetail(null)} />
    </Stack>
  );
}
