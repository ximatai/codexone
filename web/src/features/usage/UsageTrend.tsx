import { BarChart } from "@mantine/charts";
import { Box, Group } from "@mantine/core";
import type { UsageReport } from "./api";
import { businessTime, dayStart } from "../../shared/business-day";
import { UsageChartCard } from "./UsageChartCard";
import styles from "./usage.module.css";

const series = [
  { name: "admitted", label: "已准入", color: "brand.7" },
  { name: "rejected", label: "已记录准入前拒绝", color: "brand.3" },
];

export function UsageTrend({ report }: { report: UsageReport }) {
  const daily = report.buckets.length > 168;
  const interval = daily ? "按日" : "按小时";
  const timezone = report.timezone ?? "UTC";
  const grouped = new Map<number, { admitted: number; rejected: number }>();
  for (const point of report.buckets) {
    const at = daily
      ? dayStart(point.atUnixSeconds, report.businessDay?.offsetMinutes)
      : point.atUnixSeconds;
    const item = grouped.get(at) ?? { admitted: 0, rejected: 0 };
    item.admitted += point.admitted;
    item.rejected += point.recordedRejections;
    grouped.set(at, item);
  }
  const points = [...grouped].map(([at, item]) => ({
    at: businessTime(at, report.businessDay?.offsetMinutes).slice(
      5,
      daily ? 10 : 16,
    ),
    admitted: item.admitted,
    rejected: item.rejected,
  }));
  return (
    <UsageChartCard
      title="请求趋势"
      caption={
        <Group gap="xs">
          <span>
            {interval} · {timezone}
          </span>
          {series.map(({ name, color, label }) => (
            <Group key={name} gap={4} wrap="nowrap" c="text">
              <Box
                component="span"
                className={styles.chartLegendDot}
                bg={color}
                aria-hidden="true"
              />
              <span>{label}</span>
            </Group>
          ))}
        </Group>
      }
    >
      <div
        role="img"
        aria-label={`${timezone} ${interval}请求趋势，已准入 ${report.totals.admitted}，已记录拒绝 ${report.totals.recordedRejections}`}
      >
        <BarChart
          h={176}
          data={points}
          dataKey="at"
          type="stacked"
          series={series}
          barProps={{ isAnimationActive: false }}
        />
      </div>
    </UsageChartCard>
  );
}
