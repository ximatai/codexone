import {
  ContinuousValue,
  useOverviewMotion,
} from "../../shared/ui/ContinuousValue";
import {
  IconArrowUp,
  IconArrowDown,
  IconSend,
  IconDatabase,
  IconCurrencyDollar,
  IconAlertTriangle,
} from "@tabler/icons-react";
import { AreaChart } from "@mantine/charts";
import {
  Group,
  Paper,
  Text,
  ThemeIcon,
  Skeleton,
  Tooltip,
} from "@mantine/core";
import {
  change,
  pointChange,
  tokenTotal,
  type DailyBucket,
} from "./round2-api";
import { failures } from "../../shared/presentation";
import {
  compactCount,
  compactMoney,
  type CapacityMetric,
} from "./overview-format";
import styles from "./overview.module.css";
function Sparkline({
  values,
  label,
}: {
  values: (number | null)[];
  label: string;
}) {
  const motion = useOverviewMotion();
  return (
    <div
      className={styles.sparkline}
      role="img"
      aria-label={`${label}近 7 天：${values.map((v) => (v === null ? "不可用" : Number(v.toFixed(1)))).join("、")}`}
    >
      <AreaChart
        h={64}
        data={values.map((value, index) => ({ day: String(index), value }))}
        dataKey="day"
        series={[{ name: "value", color: "brand.5" }]}
        withXAxis={false}
        withYAxis={false}
        withTooltip={false}
        withDots={false}
        withLegend={false}
        gridAxis="none"
        connectNulls={false}
        fillOpacity={0.2}
        areaProps={{ isAnimationActive: motion, animationDuration: 250 }}
        curveType="monotone"
      />
    </div>
  );
}
export function OverviewStats({
  buckets,
  loading = false,
  capacities,
}: {
  buckets: DailyBucket[];
  loading?: boolean;
  capacities?: CapacityMetric[];
}) {
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
  const cards = [
    {
      label: "今日已准入",
      value: today ? compactCount(today.requests) : "—",
      exact: today?.requests.toLocaleString("zh-CN"),
      values: buckets.map((b) => b.requests),
      delta: change(today?.requests, yesterday?.requests),
      note: today
        ? `已记录准入前拒绝 ${today.recordedRejections?.toLocaleString("zh-CN") ?? "不可用"}`
        : "",
    },
    {
      label: "Token",
      value:
        today && tokenTotal(today) !== null
          ? compactCount(
              BigInt(today.metrics.inputTokens!) +
                BigInt(today.metrics.outputTokens!),
            )
          : "不可用",
      exact:
        today && tokenTotal(today) !== null
          ? (
              BigInt(today.metrics.inputTokens!) +
              BigInt(today.metrics.outputTokens!)
            ).toLocaleString("zh-CN")
          : undefined,
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
      label: "估算费用",
      value:
        today?.metrics.estimatedMicros == null
          ? "不可用"
          : `$${(Number(today.metrics.estimatedMicros) / 1000000).toFixed(2)}`,
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
      note: "",
    },
    {
      label: "错误率",
      value:
        errorRate(today) === null ? "—" : `${errorRate(today)!.toFixed(1)}%`,
      values: buckets.map(errorRate),
      delta: pointChange(errorRate(today), errorRate(yesterday)),
      note: mainFailure
        ? `失败请求中：${failures[mainFailure[0]] ?? "其他异常"}占 ${((mainFailure[1] / failureCount) * 100).toFixed(0)}%`
        : today
          ? today.cancelled
            ? `暂无失败类别 · 客户端取消 ${today.cancelled}`
            : "暂无失败类别"
          : "失败类别不可用",
    },
  ];
  return (
    <div
      className={styles.kpis}
      aria-busy={loading}
      aria-label={loading ? "正在读取请求概览…" : "关键指标"}
    >
      {cards.map((card, index) => (
        <Paper key={card.label} withBorder p="md">
          {loading ? (
            <Skeleton h={190} />
          ) : (
            <>
              <Group gap="sm">
                <ThemeIcon
                  variant="light"
                  size={40}
                  radius="xl"
                  color={index === 3 ? "red" : "brand"}
                >
                  {index === 0 ? (
                    <IconSend size={22} />
                  ) : index === 1 ? (
                    <IconDatabase size={22} />
                  ) : index === 2 ? (
                    <IconCurrencyDollar size={22} />
                  ) : (
                    <IconAlertTriangle size={22} />
                  )}
                </ThemeIcon>
                <Text
                  size="sm"
                  title={
                    [
                      "业务日当日已准入请求，不含准入前拒绝。",
                      "已观测输入与输出之和，缓存包含在输入中；缺失用量未补零。",
                      "按配置费率估算，非账单；缺失用量未计入。",
                      "失败数除以已准入请求数，客户端取消单独统计。",
                    ][index]
                  }
                >
                  {card.label}
                </Text>
              </Group>
              <Group gap="xs" align="baseline">
                <Text
                  className={styles.metricValue}
                  size="28px"
                  fw={700}
                  lh={1.2}
                  mt="xs"
                  title={card.exact}
                  tabIndex={card.exact ? 0 : undefined}
                >
                  <ContinuousValue text={card.value} />
                </Text>
                {card.delta !== "较昨日不可用" && (
                  <Text
                    size="xs"
                    c={
                      index === 3 && card.delta.includes("+")
                        ? "red"
                        : index === 3 && card.delta.includes("-")
                          ? "green"
                          : "dimmed"
                    }
                  >
                    {card.delta.includes("+") ? (
                      <IconArrowUp size={12} />
                    ) : card.delta.includes("-") ? (
                      <IconArrowDown size={12} />
                    ) : null}
                    {card.delta}
                  </Text>
                )}
              </Group>
              {card.note && (
                <Text size="xs" c="dimmed">
                  {card.note}
                </Text>
              )}
              <Sparkline label={card.label} values={card.values} />
              {capacities
                ?.filter(
                  (value) =>
                    value.name ===
                    (index === 0
                      ? "daily_requests"
                      : index === 2
                        ? "daily_estimated_micros"
                        : ""),
                )
                .map((value) => (
                  <Tooltip
                    key={value.name}
                    label={
                      value.blocking
                        ? "达到上限会阻断请求。"
                        : "仅用于提醒，达到参考阈值不会阻断请求。"
                    }
                  >
                    <Text size="xs" c="dimmed" tabIndex={0}>
                      {value.blocking ? "阻断上限" : "参考阈值"}{" "}
                      {index === 2
                        ? compactMoney(value.limit)
                        : compactCount(value.limit)}{" "}
                      ·{" "}
                      {value.current === null || BigInt(value.limit) === 0n
                        ? "比例不可用"
                        : `已用 ${(Number((BigInt(value.current) * 1000n) / BigInt(value.limit)) / 10).toFixed(1)}%`}
                    </Text>
                  </Tooltip>
                ))}
            </>
          )}
        </Paper>
      ))}
    </div>
  );
}
