import {
  ContinuousValue,
  useOverviewMotion,
} from "../../shared/ui/ContinuousValue";
import {
  IconSend,
  IconDatabase,
  IconPhoto,
  IconAlertTriangle,
} from "@tabler/icons-react";
import { AreaChart } from "@mantine/charts";
import { Group, Paper, Text, ThemeIcon, Skeleton, Title } from "@mantine/core";
import { tokenTotal, type DailyBucket } from "./round2-api";
import { failures } from "../../shared/presentation";
import { compactCount } from "./overview-format";
import styles from "./overview.module.css";
const chartDay = new Intl.DateTimeFormat("zh-CN", {
  month: "long",
  day: "numeric",
  timeZone: "UTC",
});

function Sparkline({
  values,
  dates,
  format,
  label,
  compact = true,
}: {
  values: (number | null)[];
  dates: string[];
  format: (value: number, index: number) => string;
  label: string;
  compact?: boolean;
}) {
  const motion = useOverviewMotion();
  return (
    <div
      className={compact ? styles.sparkline : undefined}
      role="img"
      aria-label={`${label}近 7 天：${values.map((v) => (v === null ? "不可用" : Number(v.toFixed(compact ? 1 : 5)))).join("、")}`}
    >
      <AreaChart
        h={compact ? 64 : 104}
        data={values.map((value, index) => ({ day: String(index), value }))}
        dataKey="day"
        series={[{ name: "value", color: "brand.5" }]}
        withXAxis={false}
        withYAxis={false}
        tooltipAnimationDuration={0}
        tooltipProps={{
          filterNull: false,
          content: ({ active, label: day }) => {
            if (!active || day == null) return null;
            const index = Number(day);
            const value = values[index];
            if (!dates[index]) return null;
            return (
              <Paper withBorder p="xs" shadow="sm" role="tooltip">
                <Text size="xs" c="dimmed">
                  {dates[index]}
                </Text>
                <Text size="sm" fw={600}>
                  {value == null ? "不可用" : format(value, index)}
                </Text>
              </Paper>
            );
          },
        }}
        withDots={!compact}
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
export function OutputRateTrend({
  buckets,
  rates,
  offsetMinutes = 0,
}: {
  buckets: DailyBucket[];
  rates?: Readonly<Record<string, number>>;
  offsetMinutes?: number;
}) {
  const values = buckets.map(
    ({ atUnixSeconds }) => rates?.[atUnixSeconds] ?? null,
  );
  return (
    <Paper withBorder p="md">
      <Title order={3} size="h4">
        输出吞吐
      </Title>
      <Text
        size="xs"
        c="dimmed"
        mt={4}
        title="按结算日统计，仅以有输出 Token 结算的秒数计算。"
      >
        近 7 天
      </Text>
      {values.some((value) => value !== null) ? (
        <Sparkline
          label="活跃时段输出吞吐"
          values={values}
          dates={buckets.map((bucket) =>
            chartDay.format((bucket.atUnixSeconds + offsetMinutes * 60) * 1000),
          )}
          format={(value) =>
            `${value.toLocaleString("zh-CN", { maximumFractionDigits: 5 })} Token/s`
          }
          compact={false}
        />
      ) : (
        <Text size="sm" c="dimmed" mt="sm">
          暂无吞吐数据
        </Text>
      )}
    </Paper>
  );
}

export function OverviewStats({
  buckets,
  timezone,
  offsetMinutes = 0,
  loading = false,
}: {
  buckets: DailyBucket[];
  timezone?: string;
  offsetMinutes?: number;
  loading?: boolean;
}) {
  const today = buckets.at(-1);
  const todayImages = today?.metrics.images;
  const errorRate = (bucket: typeof today) => {
    if (!bucket) return null;
    const eligible = bucket.requests - bucket.cancelled;
    return eligible > 0 ? (bucket.failed / eligible) * 100 : null;
  };
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
  const dates = buckets.map((bucket) =>
    chartDay.format((bucket.atUnixSeconds + offsetMinutes * 60) * 1000),
  );
  const cards = [
    {
      label: "今日已准入",
      value: today ? compactCount(today.requests) : "—",
      exact: today?.requests.toLocaleString("zh-CN"),
      values: buckets.map((b) => b.requests),
      format: (value: number) => value.toLocaleString("zh-CN"),
      note: today
        ? `拒绝 ${today.recordedRejections?.toLocaleString("zh-CN") ?? "不可用"}`
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
      format: (_: number, index: number) => {
        const metrics = buckets[index].metrics;
        return (
          BigInt(metrics.inputTokens!) + BigInt(metrics.outputTokens!)
        ).toLocaleString("zh-CN");
      },
      note:
        today?.metrics.cachedTokens != null &&
        today.metrics.inputTokens != null &&
        BigInt(today.metrics.inputTokens) > 0n
          ? `缓存 ${((Number(today.metrics.cachedTokens) / Number(today.metrics.inputTokens)) * 100).toFixed(1)}%`
          : "",
    },
    {
      label: "生图张数",
      format: (_: number, index: number) =>
        `${BigInt(buckets[index].metrics.images!).toLocaleString("zh-CN")} 张`,
      value: todayImages == null ? "—" : compactCount(todayImages),
      exact:
        todayImages == null
          ? undefined
          : BigInt(todayImages).toLocaleString("zh-CN"),
      values: buckets.map(({ metrics }) =>
        metrics.images == null ? null : Number(metrics.images),
      ),
      note: "",
    },
    {
      label: "错误率",
      format: (value: number) => `${value.toFixed(1)}%`,
      value:
        errorRate(today) === null ? "—" : `${errorRate(today)!.toFixed(1)}%`,
      values: buckets.map(errorRate),
      count: today ? `失败 ${today.failed.toLocaleString("zh-CN")}` : undefined,
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
                    <IconPhoto size={22} />
                  ) : (
                    <IconAlertTriangle size={22} />
                  )}
                </ThemeIcon>
                <Text
                  size="sm"
                  title={
                    [
                      `业务日当日已准入请求${timezone ? `（${timezone}）` : ""}，不含准入前拒绝。`,
                      "已观测输入与输出之和，缓存包含在输入中；缺失用量未补零。",
                      "已观测到的图片产出，包含原生图片接口和 Responses 图片工具。未观测到的数据不补零。",
                      "失败数除以扣除客户端取消后的已准入请求数。",
                    ][index]
                  }
                >
                  {card.label}
                </Text>
              </Group>
              <div className={styles.metricRow}>
                <Text
                  className={styles.metricValue}
                  size="28px"
                  fw={700}
                  lh={1.2}
                  title={card.exact}
                  tabIndex={card.exact ? 0 : undefined}
                >
                  <ContinuousValue text={card.value} />
                </Text>
                <Text
                  className={styles.metricNote}
                  size="xs"
                  c="dimmed"
                  title={
                    index === 0 && card.note
                      ? `准入前${card.note}`
                      : card.note || undefined
                  }
                >
                  {card.count ?? card.note}
                </Text>
              </div>
              <Sparkline
                label={card.label}
                values={card.values}
                dates={dates}
                format={card.format}
              />
            </>
          )}
        </Paper>
      ))}
    </div>
  );
}
