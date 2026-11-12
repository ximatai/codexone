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
import { AreaChart, LineChart } from "@mantine/charts";
import { Dot } from "recharts";
import {
  Anchor,
  Group,
  Paper,
  Text,
  ThemeIcon,
  Skeleton,
  Title,
} from "@mantine/core";
import { tokenTotal, type DailyBucket } from "./round2-api";
import { Link } from "react-router";
import { businessDate } from "../../shared/business-day";
import { failures } from "../../shared/presentation";
import { compactCount, compactOverviewTokens } from "./overview-format";
import styles from "./overview.module.css";
import type { HourlyOutputRate } from "./useOverviewLive";
const outputTrendHeight = 108;
const outputTrendHours = 168;
const maxBridgedHours = 2;
const outputDateTicks = [0, 56, 112, outputTrendHours - 1];
const chartShortDay = new Intl.DateTimeFormat("en-US", {
  month: "2-digit",
  day: "2-digit",
  timeZone: "UTC",
});
const axisRateFormat = new Intl.NumberFormat("zh-CN", {
  notation: "compact",
  maximumFractionDigits: 1,
});
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
}: {
  values: (number | null)[];
  dates: string[];
  format: (value: number, index: number) => string;
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
        withDots={false}
        withLegend={false}
        gridAxis="none"
        connectNulls={false}
        fillOpacity={0.2}
        areaProps={{
          isAnimationActive: motion,
          animationDuration: 250,
          activeDot: false,
        }}
        curveType="monotone"
      />
    </div>
  );
}
const chartHour = new Intl.DateTimeFormat("zh-CN", {
  month: "long",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
  timeZone: "UTC",
});

export function OutputRateTrend({ history }: { history?: HourlyOutputRate }) {
  const hours = history
    ? Array.from({ length: outputTrendHours }, (_, index) => {
        const hour =
          history.endUnixSeconds - (outputTrendHours - 1 - index) * 3600;
        const point = history.points[hour];
        return {
          index,
          businessTime: (hour + history.offsetMinutes * 60) * 1000,
          value: point?.median ?? null,
          count: point?.count,
        };
      })
    : [];
  const observed = hours.flatMap(({ index, value }) =>
    value === null ? [] : [{ index, value }],
  );
  const latest = observed.at(-1);
  const bridges = observed.slice(1).flatMap((end, index) => {
    const start = observed[index];
    const missing = end.index - start.index - 1;
    if (missing < 1 || missing > maxBridgedHours) return [];
    return [
      {
        segment: [
          { x: start.index, y: start.value },
          { x: end.index, y: end.value },
        ] as const,
        className: styles.outputRateBridge,
        strokeDasharray: "2 2",
      },
    ];
  });
  const rate = (value: number) =>
    value.toLocaleString("zh-CN", { maximumFractionDigits: 0 });
  return (
    <Paper withBorder p="md">
      <Group justify="space-between" align="baseline" gap="xs" wrap="nowrap">
        <Title
          order={3}
          size="h4"
          title="每小时取最近至多 256 笔已结算请求的速率中位数，包含首输出前的等待。"
        >
          Token 输出速率
        </Title>
        {latest && (
          <div className={styles.outputRateValue} title="最近有样本的小时">
            <Text component="span" size="xs" c="dimmed">
              最近
            </Text>
            <ContinuousValue text={rate(latest.value)} />
            <Text component="span" size="xs" c="dimmed">
              Token/s
            </Text>
          </div>
        )}
      </Group>
      {latest ? (
        <div
          role="img"
          aria-label={`Token 输出速率近 7 天：最近有样本的小时 ${rate(latest.value)} Token/s`}
        >
          <LineChart
            h={outputTrendHeight}
            mt={4}
            data={hours}
            dataKey="index"
            series={[{ name: "value", color: "brand.5" }]}
            lineChartProps={{
              margin: { top: 5, right: 17, bottom: 0, left: 0 },
            }}
            xAxisProps={{
              type: "number",
              domain: [0, outputTrendHours - 1],
              ticks: outputDateTicks,
              interval: 0,
              height: 18,
              tickSize: 3,
              axisLine: false,
              tick: { fontSize: 10, fill: "currentColor" },
              tickFormatter: (index) =>
                chartShortDay.format(hours[index].businessTime),
              padding: { left: 8, right: 0 },
            }}
            yAxisProps={{
              width: 27,
              tickCount: 3,
              allowDecimals: false,
              domain: [0, "auto"],
              tickSize: 3,
              tick: { fontSize: 10, fill: "currentColor" },
              tickFormatter: (value) => axisRateFormat.format(value),
            }}
            tickLine="none"
            strokeDasharray="0"
            strokeWidth={1.5}
            connectNulls={false}
            curveType="linear"
            referenceLines={bridges}
            lineProps={{
              activeDot: { r: 3 },
              dot: ({ index, cx, cy, stroke }) =>
                hours[index]?.value != null &&
                (index === latest.index ||
                  (hours[index - 1]?.value == null &&
                    hours[index + 1]?.value == null)) ? (
                  <Dot cx={cx} cy={cy} r={2} fill={stroke} />
                ) : null,
            }}
            tooltipProps={{
              filterNull: false,
              content: ({ active, label }) => {
                const hour = label == null ? undefined : hours[Number(label)];
                if (!active || !hour) return null;
                return (
                  <Paper withBorder p="xs" shadow="sm" role="tooltip">
                    <Text size="xs" c="dimmed">
                      {chartHour.format(hour.businessTime)}
                    </Text>
                    <Text size="sm" fw={600}>
                      {hour.value == null
                        ? "无样本"
                        : `${rate(hour.value)} Token/s · ${hour.count} 笔样本`}
                    </Text>
                  </Paper>
                );
              },
            }}
          />
        </div>
      ) : (
        <Text size="sm" c="dimmed" h={outputTrendHeight} mt={4} pt="sm">
          暂无速率数据
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
  const rejectionDay = today
    ? businessDate(today.atUnixSeconds, offsetMinutes)
    : undefined;
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
          ? compactOverviewTokens(
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
        <Paper key={card.label} withBorder p="md" className={styles.metricCard}>
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
                {index === 0 &&
                rejectionDay &&
                (today?.recordedRejections ?? 0) > 0 ? (
                  <Anchor
                    className={styles.metricNote}
                    size="xs"
                    component={Link}
                    to={`/usage?start=${rejectionDay}&end=${rejectionDay}&rejectedOnly=true`}
                    aria-label={`查看今日${card.note}条记录`}
                  >
                    {card.note}
                  </Anchor>
                ) : (
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
                )}
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
