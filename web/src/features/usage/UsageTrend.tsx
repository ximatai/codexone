import { BarChart } from "@mantine/charts";
import { Paper, Title, Text } from "@mantine/core";
import type { UsageReport } from "./api";
import { utc } from "./format";
import styles from "./usage.module.css";
export function UsageTrend({ report }: { report: UsageReport }) {
  const daily = report.buckets.length > 168;
  const grouped = new Map<
    number,
    { admitted: number; rejected: number; unresolved: number }
  >();
  for (const point of report.buckets) {
    const at = daily
      ? Math.floor(point.atUnixSeconds / 86400) * 86400
      : point.atUnixSeconds;
    const item = grouped.get(at) ?? { admitted: 0, rejected: 0, unresolved: 0 };
    item.admitted += point.admitted;
    item.rejected += point.recordedRejections;
    item.unresolved += point.unresolved;
    grouped.set(at, item);
  }
  const points = [...grouped].map(([at, item]) => ({
    at: utc(at).slice(5, daily ? 10 : 16),
    admitted: item.admitted,
    rejected: item.rejected,
  }));
  return (
    <Paper withBorder p="md" className={styles.trend}>
      <Title order={3} mb="xs">
        请求趋势{" "}
        <Text component="span" size="xs" c="dimmed">
          UTC · 按{daily ? "日" : "小时"}
        </Text>
      </Title>
      <div
        role="img"
        aria-label={`UTC 按${daily ? "日" : "小时"}请求趋势，已准入 ${report.totals.admitted}，已记录拒绝 ${report.totals.recordedRejections}`}
      >
        <BarChart
          h={200}
          data={points}
          dataKey="at"
          type="stacked"
          withLegend
          series={[
            { name: "admitted", label: "已准入", color: "green.8" },
            { name: "rejected", label: "已记录准入前拒绝", color: "green.3" },
          ]}
          barProps={{ isAnimationActive: false }}
        />
      </div>
    </Paper>
  );
}
