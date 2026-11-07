import { ContinuousValue } from "../../shared/ui/ContinuousValue";
import { useEffect, useMemo, useState } from "react";
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
import { compactCount, compactKeyTokens } from "./overview-format";
import styles from "./overview.module.css";

export function highFailure(
  row: Pick<KeySummary, "admitted" | "failed" | "cancelled">,
) {
  const eligible = row.admitted - row.cancelled;
  return (
    eligible >= 20 &&
    row.failed >= 5 &&
    BigInt(row.failed) * 5n >= BigInt(eligible)
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
  query: Pick<
    UseQueryResult<KeySummaryReport, Error>,
    "data" | "isError" | "isPending" | "dataUpdatedAt" | "refetch"
  >;
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
  const rows = useMemo(
    () =>
      [...(report?.keys ?? [])]
        .filter((row) => row.admitted > 0)
        .sort((a, b) => {
          if (a.tokens == null && b.tokens != null) return 1;
          if (a.tokens != null && b.tokens == null) return -1;
          const left = BigInt(a.tokens ?? 0);
          const right = BigInt(b.tokens ?? 0);
          if (left !== right) return left > right ? -1 : 1;
          return (
            (b.lastUsedAtUnixSeconds ?? -1) - (a.lastUsedAtUnixSeconds ?? -1) ||
            a.keyID.localeCompare(b.keyID)
          );
        }),
    [report?.keys],
  );
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
          <Group gap={6} wrap="nowrap" className={styles.keyIdentity}>
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
          <ContinuousValue text={compactCount(row.admitted)} />
        </Text>
      ),
    },
    {
      id: "failed",
      title: "失败率",
      width: "17%",
      render: (row) => {
        const eligible = row.admitted - row.cancelled;
        if (eligible <= 0 || !report) return <Text size="sm">—</Text>;
        const rate = percent(BigInt(row.failed), BigInt(eligible));
        return (
          <Anchor
            component={Link}
            to={failureLink(row, report)}
            size="sm"
            c={highFailure(row) ? "orange.8" : undefined}
            aria-label={`${name(row)} 失败率 ${rate}`}
            title="查看失败请求"
          >
            <ContinuousValue text={rate} />
          </Anchor>
        );
      },
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
          <ContinuousValue
            text={
              row.tokens == null
                ? "—"
                : `${row.tokenUsageIncomplete ? "≥ " : ""}${compactKeyTokens(row.tokens)}`
            }
          />
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
          <ContinuousValue text={cacheRate(row)} />
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
            title="业务日内有准入的未归档 Key，按已观测 Token 降序；不含准入前拒绝。"
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
          <Text
            size="xs"
            c={oldWindow || query.isError ? "orange.8" : "dimmed"}
            role={query.isError ? "status" : undefined}
            title={snapshot}
          >
            {query.isError
              ? `更新失败 · 上次更新 ${businessTime(query.dataUpdatedAt / 1000, offset)}`
              : `${oldWindow ? "旧业务日快照 · " : ""}${snapshot}`}
          </Text>
        )}
      </Group>
      {query.isError && !report ? (
        <Text size="sm" c="dimmed">
          Key 汇总读取失败
        </Text>
      ) : (
        <DataTable
          animate
          rows={rows}
          columns={columns}
          rowKey={(row) => row.keyID}
          loading={query.isPending}
          retry={() => void query.refetch()}
          empty="暂无活跃 Key"
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
