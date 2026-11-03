import { useEffect, useState } from "react";
import {
  ActionIcon,
  Anchor,
  Badge,
  Button,
  Drawer,
  Group,
  Paper,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { Link } from "react-router";
import { IconExternalLink } from "@tabler/icons-react";
import type { UseQueryResult } from "@tanstack/react-query";
import { DataTable, type DataColumn } from "../../shared/ui/DataTable";
import { businessDate, businessTime } from "../../shared/business-day";
import type { KeySummary, KeySummaryReport } from "./round2-api";
import { compactCount } from "./overview-format";
import styles from "./overview.module.css";

export function highFailure(row: Pick<KeySummary, "admitted" | "failed">) {
  return (
    row.admitted >= 20 &&
    row.failed >= 5 &&
    BigInt(row.failed) * 5n >= BigInt(row.admitted)
  );
}
function percent(part: bigint, total: bigint) {
  return `${Number((part * 1000n + total / 2n) / total) / 10}%`;
}
export function cacheRate(
  row: Pick<KeySummary, "inputTokens" | "cachedTokens">,
) {
  if (
    row.inputTokens == null ||
    BigInt(row.inputTokens) === 0n ||
    row.cachedTokens == null
  )
    return "—";
  return percent(BigInt(row.cachedTokens), BigInt(row.inputTokens));
}
export function failureLink(row: KeySummary, report: KeySummaryReport) {
  return (
    "/usage?" +
    new URLSearchParams({
      key: row.keyID,
      start: businessDate(
        report.startUnixSeconds,
        report.businessDay.offsetMinutes,
      ),
      end: businessDate(
        report.endUnixSeconds - 1,
        report.businessDay.offsetMinutes,
      ),
      outcome: "failed",
    })
  );
}
export function KeyResults({
  query,
}: {
  query: UseQueryResult<KeySummaryReport, Error>;
}) {
  const [detail, setDetail] = useState<{
    row: KeySummary;
    snapshot: string;
  } | null>(null);
  const [now, setNow] = useState(Date.now() / 1000);
  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!document.hidden) setNow(Date.now() / 1000);
    }, 15000);
    return () => window.clearInterval(timer);
  }, []);
  const report = query.data;
  const offset = report?.businessDay.offsetMinutes ?? 0;
  const oldWindow =
    report && (now < report.startUnixSeconds || now >= report.endUnixSeconds);
  const snapshot = report
    ? `${businessDate(report.startUnixSeconds, offset)} · ${report.timezone}`
    : "";
  const refreshedDetail =
    detail && report?.keys.find((row) => row.keyID === detail.row.keyID);
  const detailRow = refreshedDetail ?? detail?.row;
  const detailSnapshot = refreshedDetail ? snapshot : detail?.snapshot;
  const unknown = (row: KeySummary) =>
    row.admitted - row.succeeded - row.failed - row.cancelled - row.inFlight;
  const name = (row: KeySummary) =>
    row.displayName ||
    (row.principal?.startsWith("legacy-p-") ? "未命名 Key" : row.principal) ||
    "未命名 Key";
  const columns: DataColumn<KeySummary>[] = [
    {
      id: "key",
      title: "Key",
      width: "27%",
      render: (row) => (
        <Stack gap={4} align="flex-start">
          <Group gap={6}>
            <Button
              variant="subtle"
              size="compact-sm"
              className={styles.keyButton}
              title={`${row.principal ?? "主体未记录"} · ${row.keyID}`}
              onClick={() => setDetail({ row, snapshot })}
            >
              {name(row)}
            </Button>
            {row.inFlight > 0 && (
              <Badge color="blue" aria-label={`执行中 ${row.inFlight}`}>
                执行中 {row.inFlight}
              </Badge>
            )}
            {row.enabled === false && <Badge color="gray">已停用</Badge>}
          </Group>
          {(row.cancelled > 0 || unknown(row) > 0) && (
            <Group gap={8}>
              {row.cancelled > 0 && (
                <Text size="xs" aria-label={`取消 ${row.cancelled}`}>
                  取消 {row.cancelled}
                </Text>
              )}
              {unknown(row) > 0 && (
                <Text size="xs" aria-label={`结果未明 ${unknown(row)}`}>
                  结果未明 {unknown(row)}
                </Text>
              )}
            </Group>
          )}
        </Stack>
      ),
    },
    {
      id: "lastUsed",
      title: "最近活动",
      width: "20%",
      render: (row) => (
        <Text
          size="xs"
          title={
            row.lastUsedAtUnixSeconds == null
              ? undefined
              : businessTime(row.lastUsedAtUnixSeconds, offset)
          }
        >
          {row.lastUsedAtUnixSeconds == null
            ? "未记录"
            : businessTime(row.lastUsedAtUnixSeconds, offset).slice(5, 16)}
        </Text>
      ),
    },
    {
      id: "admitted",
      title: "请求",
      width: "10%",
      render: (row) => (
        <Text size="sm" title={row.admitted.toLocaleString("zh-CN")}>
          {compactCount(row.admitted)}
        </Text>
      ),
    },
    {
      id: "failed",
      title: "失败",
      width: "17%",
      render: (row) => (
        <Stack gap={2} align="flex-start">
          {row.failed > 0 && report ? (
            <Anchor
              component={Link}
              to={failureLink(row, report)}
              size="sm"
              c={highFailure(row) ? "orange.8" : undefined}
              aria-label={`${name(row)} 失败 ${row.failed}`}
              title="失败率以已准入请求为分母；取消、执行中和结果未明不计为失败。"
            >
              {compactCount(row.failed)}（
              {percent(BigInt(row.failed), BigInt(row.admitted))}）
            </Anchor>
          ) : (
            <Text size="sm">0（0%）</Text>
          )}
          {highFailure(row) && (
            <Text
              size="xs"
              c="orange.8"
              title="已准入至少 20 次、失败至少 5 次且失败率至少 20%。"
            >
              失败偏高
            </Text>
          )}
        </Stack>
      ),
    },
    {
      id: "tokens",
      title: "Token",
      width: "13%",
      render: (row) => (
        <Text
          size="sm"
          title={
            row.tokens == null
              ? "无 Token 观测"
              : `${row.tokenUsageIncomplete ? "已观测下界 " : ""}${BigInt(row.tokens).toLocaleString("zh-CN")}`
          }
        >
          {row.tokens == null
            ? "—"
            : `${row.tokenUsageIncomplete ? "≥ " : ""}${compactCount(row.tokens)}`}
        </Text>
      ),
    },
    {
      id: "cache",
      title: "缓存命中率",
      width: "13%",
      render: (row) => (
        <Text
          size="sm"
          title={`按已观测用量的累计缓存 Token / 输入 Token 计算。${row.cacheUsageIncomplete !== false ? "部分请求没有完整宿主用量，仅使用已观测输入；无用量请求不进入分母。" : ""}`}
        >
          {cacheRate(row)}
        </Text>
      ),
    },
  ];
  return (
    <Paper
      withBorder
      p="md"
      component="section"
      aria-label="今日 Key 请求汇总"
      className={styles.keySummary}
    >
      <Group justify="space-between" gap="xs" mb="sm">
        <Group gap={4}>
          <Title
            order={3}
            size="h4"
            title="业务日内有准入的未归档 Key，按最近准入倒序；不含准入前拒绝。"
          >
            今日 Key 请求汇总
          </Title>
          <ActionIcon
            component={Link}
            to="/usage"
            variant="subtle"
            size="sm"
            aria-label="查看用量与诊断"
          >
            <IconExternalLink size={16} />
          </ActionIcon>
        </Group>
        {report && (
          <Text size="xs" c={oldWindow ? "orange.8" : "dimmed"}>
            {oldWindow ? "旧业务日快照 · " : ""}
            {snapshot}
          </Text>
        )}
      </Group>
      {query.isError && report && (
        <Text role="status" c="orange.8" size="sm">
          读取失败，保留上次成功快照（
          {businessTime(query.dataUpdatedAt / 1000, offset)}）。
        </Text>
      )}
      {query.isError && !report ? (
        <Text size="sm" c="dimmed">
          今日 Key 汇总读取失败。请重试。
        </Text>
      ) : (
        <DataTable
          rows={[...(report?.keys ?? [])]
            .filter((row) => row.admitted > 0)
            .sort(
              (a, b) =>
                (b.lastUsedAtUnixSeconds ?? -1) -
                  (a.lastUsedAtUnixSeconds ?? -1) ||
                a.keyID.localeCompare(b.keyID),
            )}
          columns={columns}
          rowKey={(row) => row.keyID}
          loading={query.isPending}
          retry={() => void query.refetch()}
          empty="今日暂无活跃 Key。"
        />
      )}
      <Drawer
        opened={detail !== null}
        onClose={() => setDetail(null)}
        title="Key 详情"
        size="sm"
        closeButtonProps={{ "aria-label": "关闭" }}
        lockScroll={false}
        removeScrollProps={{ enabled: false }}
        data-ui-overlay={detail !== null ? "true" : undefined}
      >
        {detailRow && (
          <Stack>
            <Text fw={600}>{name(detailRow)}</Text>
            <Text className="wrap-anywhere">
              主体：{detailRow.principal ?? "未记录"}
            </Text>
            <Text className="wrap-anywhere">Key ID：{detailRow.keyID}</Text>
            <Text>{detailSnapshot}</Text>
            <Text>
              请求：{detailRow.admitted.toLocaleString("zh-CN")} · 失败：
              {detailRow.failed.toLocaleString("zh-CN")}
            </Text>
            <Text>
              Token：{detailRow.tokenUsageIncomplete ? "≥ " : ""}
              {detailRow.tokens == null
                ? "未观测"
                : BigInt(detailRow.tokens).toLocaleString("zh-CN")}
            </Text>
            <Text>
              缓存 / 输入 Token：{detailRow.cachedTokens ?? "未观测"} /{" "}
              {detailRow.inputTokens ?? "未观测"}
            </Text>
            {detailRow.cacheUsageIncomplete && (
              <Text size="sm">
                部分请求没有完整宿主用量，缓存率只使用已观测输入。
              </Text>
            )}
          </Stack>
        )}
      </Drawer>
    </Paper>
  );
}
