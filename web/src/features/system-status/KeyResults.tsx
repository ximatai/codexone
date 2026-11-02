import { Anchor, Group, Paper, Text, Title } from "@mantine/core";
import { Link } from "react-router";
import type { UseQueryResult } from "@tanstack/react-query";
import { KeyName } from "../../shared/KeyName";
import { DataTable, type DataColumn } from "../../shared/ui/DataTable";
import type { KeySummary } from "./round2-api";
import { compactCount } from "./overview-format";
import styles from "./overview.module.css";

const results = [
  ["请求", "admitted", "dark"],
  ["成功", "succeeded", "teal"],
  ["失败", "failed", "red"],
  ["取消", "cancelled", "yellow"],
  ["执行中", "inFlight", "blue"],
  ["结果未明", "unknown", "gray"],
] as const;
const columns: DataColumn<KeySummary>[] = [
  {
    id: "key",
    title: "Key",
    width: "28%",
    render: (row) => <KeyName {...row} />,
  },
  ...results.map(([label, field, color]) => ({
    id: field,
    title: label,
    width: "12%",
    render: (row: KeySummary) => {
      const value =
        field === "unknown"
          ? row.admitted -
            row.succeeded -
            row.failed -
            row.cancelled -
            row.inFlight
          : row[field];
      const exact = `${label} ${value.toLocaleString("zh-CN")}`;
      return (
        <Text
          size="sm"
          c={value ? color : "dimmed"}
          aria-label={exact}
          title={exact}
        >
          {compactCount(value)}
        </Text>
      );
    },
  })),
];
export function KeyResults({
  query,
}: {
  query: UseQueryResult<KeySummary[], Error>;
}) {
  return (
    <Paper
      withBorder
      p="md"
      component="section"
      aria-label="今日 Key 请求汇总"
      className={styles.keySummary}
    >
      <Group justify="space-between" mb="sm">
        <Title
          order={3}
          size="h4"
          title="UTC当日，按准入时间统计全部托管Key，不含准入前拒绝；结果未明不等于用量待核对。"
        >
          今日 Key 请求汇总
        </Title>
        <Anchor component={Link} to="/usage">
          查看用量与诊断
        </Anchor>
      </Group>
      {query.isError && !query.data ? (
        <Text size="sm" c="dimmed">
          今日 Key 汇总读取失败。请重试。
        </Text>
      ) : (
        <DataTable
          rows={[...(query.data ?? [])].sort(
            (a, b) => b.admitted - a.admitted || a.keyID.localeCompare(b.keyID),
          )}
          columns={columns}
          rowKey={(row) => row.keyID}
          loading={query.isPending}
          retry={() => void query.refetch()}
          empty="暂无托管 Key。"
        />
      )}
    </Paper>
  );
}
