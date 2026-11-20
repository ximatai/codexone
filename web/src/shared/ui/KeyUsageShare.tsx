import { DonutChart } from "@mantine/charts";
import { Box, Paper, Text, VisuallyHidden } from "@mantine/core";
import { compactKeyTokens } from "../compact-count";
import { PrivateName, usePrivacyMask } from "../privacy-mask";
import { UsageChartCard } from "./UsageChartCard";
import styles from "./usage-charts.module.css";

const compactRows = 4;
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
function shareLabel(ratio: number | null) {
  if (ratio === null) return "—";
  return ratio > 0 && ratio < 0.001 ? "<0.1%" : percent.format(ratio);
}

export function KeyUsageShare({
  title = "Key 用量占比",
  caption = "输入 + 输出 Token",
  emptyMessage = "当前区间没有匹配的用量记录。",
  usage,
  compact = false,
}: {
  title?: string;
  caption?: string;
  emptyMessage?: string;
  compact?: boolean;
  usage: {
    keyID: string;
    name?: string;
    incomplete: boolean;
    tokens: bigint | null;
  }[];
}) {
  const masked = usePrivacyMask();
  const entries = [...usage];
  entries.sort((a, b) => {
    const left = a.tokens ?? -1n;
    const right = b.tokens ?? -1n;
    return left === right ? 0 : left > right ? -1 : 1;
  });
  const total = entries.reduce((sum, row) => sum + (row.tokens ?? 0n), 0n);
  const remaining =
    compact && entries.length > compactRows
      ? entries.slice(compactRows - 1)
      : [];
  const unrecorded = remaining.filter((row) => row.tokens === null).length;
  const visibleEntries = remaining.length
    ? [
        ...entries.slice(0, compactRows - 1),
        {
          keyID: null,
          name: `其他（${remaining.length} 个 Key）`,
          incomplete: unrecorded > 0 || remaining.some((row) => row.incomplete),
          tokens:
            unrecorded === remaining.length
              ? null
              : remaining.reduce((sum, row) => sum + (row.tokens ?? 0n), 0n),
        },
      ]
    : entries;
  const rows = visibleEntries.map((row, index) => ({
    keyID: row.keyID,
    name: row.name,
    color:
      row.tokens && row.tokens > 0n
        ? row.keyID === null
          ? "gray.7"
          : colors[index % colors.length]
        : "gray.5",
    tokenLabel:
      row.tokens == null
        ? "未记录"
        : `${row.incomplete ? "≥ " : ""}${compactKeyTokens(row.tokens)}`,
    exactTokens:
      row.tokens == null
        ? undefined
        : `${row.incomplete ? "≥ " : ""}${row.tokens.toLocaleString("zh-CN")} Token`,
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
    <UsageChartCard
      title={title}
      caption={caption}
      className={compact ? styles.compactCard : undefined}
    >
      {!rows.length ? (
        <Text size="sm" c="dimmed">
          {emptyMessage}
        </Text>
      ) : (
        <div className={styles.keyShareContent}>
          {wedges.length > 0 && (
            <div aria-hidden="true" className={styles.keySharePlot}>
              <DonutChart
                data={wedges}
                size={compact ? 88 : 144}
                thickness={compact ? 20 : 32}
                tooltipProps={{
                  content: ({ active, payload }) => {
                    const index = payload?.[0]?.payload?.name;
                    const row =
                      typeof index === "string"
                        ? rows[Number(index)]
                        : undefined;
                    if (!active || !row) return null;
                    return (
                      <Paper withBorder p="xs" shadow="sm" role="tooltip">
                        <Text
                          size="xs"
                          className={styles.keyShareName}
                          maw={200}
                        >
                          {row.keyID === null ? (
                            row.name
                          ) : (
                            <PrivateName>{row.name}</PrivateName>
                          )}
                        </Text>
                        <Text size="sm" fw={600}>
                          {row.tokenLabel} Token · {shareLabel(row.ratio)}
                        </Text>
                      </Paper>
                    );
                  },
                }}
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
            {rows.map((row, index) => (
              <li
                // Live rankings update the contents of fixed visual slots.
                key={compact ? index : row.keyID}
                className={styles.keyShareRow}
              >
                <Box
                  component="span"
                  className={styles.chartLegendDot}
                  aria-hidden="true"
                  bg={row.color}
                />
                <span
                  className={
                    row.keyID === null
                      ? styles.aggregateName
                      : styles.keyShareName
                  }
                  title={
                    compact && (!masked || row.keyID === null)
                      ? row.name
                      : undefined
                  }
                >
                  {row.keyID === null ? (
                    row.name
                  ) : (
                    <PrivateName>{row.name}</PrivateName>
                  )}
                </span>
                <span className={styles.keyShareTokens} title={row.exactTokens}>
                  {row.tokenLabel}
                  {row.keyID === null && unrecorded > 0 && (
                    <VisuallyHidden>
                      ，含 {unrecorded} 个未记录用量的 Key
                    </VisuallyHidden>
                  )}
                </span>
                <strong className={styles.keySharePercent}>
                  {shareLabel(row.ratio)}
                </strong>
              </li>
            ))}
          </ul>
        </div>
      )}
    </UsageChartCard>
  );
}
