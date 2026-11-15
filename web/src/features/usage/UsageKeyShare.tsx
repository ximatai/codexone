import { DonutChart } from "@mantine/charts";
import { Box, Text } from "@mantine/core";
import { PrivateName } from "../../shared/privacy-mask";
import type { UsageKeyTokens } from "./api";
import { UsageChartCard } from "./UsageChartCard";
import styles from "./usage.module.css";

const colors = [
  "brand.7",
  "teal.6",
  "grape.6",
  "orange.6",
  "cyan.6",
  "lime.7",
  "pink.6",
  "indigo.4",
];
const percent = new Intl.NumberFormat("zh-CN", {
  style: "percent",
  maximumFractionDigits: 1,
});

export function UsageKeyShare({
  usage,
  labels,
}: {
  usage: UsageKeyTokens[];
  labels: Map<string, string>;
}) {
  const entries = usage.map(
    ({ keyID, incomplete, inputTokens, outputTokens }) => ({
      keyID,
      incomplete,
      tokens:
        inputTokens == null && outputTokens == null
          ? null
          : BigInt(inputTokens ?? 0) + BigInt(outputTokens ?? 0),
    }),
  );
  entries.sort((a, b) => {
    const left = a.tokens ?? -1n;
    const right = b.tokens ?? -1n;
    return left === right ? 0 : left > right ? -1 : 1;
  });
  const total = entries.reduce((sum, row) => sum + (row.tokens ?? 0n), 0n);
  const rows = entries.map((row, index) => ({
    ...row,
    color:
      row.tokens && row.tokens > 0n ? colors[index % colors.length] : "gray.5",
    ratio:
      total > 0n && row.tokens != null
        ? Number(row.tokens) / Number(total)
        : null,
  }));
  const wedges = rows.flatMap((row, index) =>
    row.ratio
      ? [{ name: String(index), value: row.ratio, color: row.color }]
      : [],
  );
  return (
    <UsageChartCard title="Key 用量占比" caption="输入 + 输出 Token">
      {!rows.length ? (
        <Text size="sm" c="dimmed">
          当前区间没有匹配的用量记录。
        </Text>
      ) : (
        <div className={styles.keyShareContent}>
          {wedges.length > 0 && (
            <div aria-hidden="true" className={styles.keySharePlot}>
              <DonutChart
                data={wedges}
                size={144}
                thickness={32}
                withTooltip={false}
                accessibilityLayer={false}
                pieProps={{ isAnimationActive: false }}
              />
            </div>
          )}
          <ul
            aria-label="各 Key 的 Token 和占比"
            className={styles.keyShareList}
            tabIndex={rows.length > 6 ? 0 : undefined}
          >
            {rows.map((row) => (
              <li key={row.keyID} className={styles.keyShareRow}>
                <Box
                  component="span"
                  className={styles.chartLegendDot}
                  aria-hidden="true"
                  bg={row.color}
                />
                <span className={styles.keyShareName}>
                  <PrivateName>{labels.get(row.keyID)}</PrivateName>
                </span>
                <span className={styles.keyShareTokens}>
                  {row.tokens == null
                    ? "未记录"
                    : `${row.incomplete ? "≥ " : ""}${row.tokens.toLocaleString("zh-CN")}`}
                </span>
                <strong className={styles.keySharePercent}>
                  {row.ratio === null
                    ? "—"
                    : row.ratio > 0 && row.ratio < 0.001
                      ? "<0.1%"
                      : percent.format(row.ratio)}
                </strong>
              </li>
            ))}
          </ul>
        </div>
      )}
    </UsageChartCard>
  );
}
