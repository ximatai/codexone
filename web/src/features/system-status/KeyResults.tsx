import { PrivateName, usePrivacyMask } from "../../shared/privacy-mask";
import { ContinuousValue } from "../../shared/ui/ContinuousValue";
import { useEffect, useMemo, useState } from "react";
import {
  ActionIcon,
  Anchor,
  Badge,
  Button,
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
import { compactCount, compactKeyTokens } from "../../shared/compact-count";
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
            (b.lastUsedTodayAtUnixSeconds ?? -1) -
              (a.lastUsedTodayAtUnixSeconds ?? -1) ||
            a.keyID.localeCompare(b.keyID)
          );
        }),
    [report?.keys],
  );
  const masked = usePrivacyMask();
  const offset = report?.businessDay.offsetMinutes ?? 0;
  const oldWindow =
    report && (now < report.startUnixSeconds || now >= report.endUnixSeconds);
  const snapshot = report
    ? `${businessDate(report.startUnixSeconds, offset)} · ${report.timezone}`
    : "";
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
      width: "23%",
      render: (row) => (
        <Stack gap={4} align="flex-start">
          <Group gap={6} wrap="nowrap" className={styles.keyIdentity}>
            <Button
              variant="subtle"
              size="compact-sm"
              className={styles.keyButton}
              title={
                masked
                  ? undefined
                  : `${row.principal ?? "主体未记录"} · ${row.keyID}`
              }
              component={Link}
              to={`/keys?${new URLSearchParams({
                status: "all",
                target: row.keyID,
                detail: row.keyID,
              })}`}
            >
              <PrivateName>{name(row)}</PrivateName>
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
      id: "activity",
      title: "活动时间",
      width: "17%",
      render: (row) => (
        <Stack gap={3}>
          {[
            { label: "最早", epoch: row.firstUsedTodayAtUnixSeconds },
            { label: "最近", epoch: row.lastUsedTodayAtUnixSeconds },
          ].map(({ label, epoch }) => {
            const time =
              epoch == null ? undefined : businessTime(epoch, offset);
            return (
              <Text
                key={label}
                size="xs"
                title={time}
                style={{
                  whiteSpace: "nowrap",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                <Text component="span" inherit c="dimmed">
                  {label}
                </Text>{" "}
                {time?.slice(11, 16) ?? "未记录"}
              </Text>
            );
          })}
        </Stack>
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
      width: "13%",
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
            aria-label={`${masked ? "已隐藏 Key" : name(row)} 失败率 ${rate}`}
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
      render: (row) => {
        const values = row.tokenBreakdown
          ? [
              { label: "输入", value: row.tokenBreakdown.input },
              { label: "输出", value: row.tokenBreakdown.output },
            ]
          : [{ label: "合计", value: row.tokens }];
        return (
          <Stack gap={3}>
            {values.map(({ label, value }) => (
              <Text
                key={label}
                size="xs"
                className={styles.keyTokenLine}
                title={
                  value == null
                    ? `${label} Token 未记录`
                    : `${label} Token ${row.tokenUsageIncomplete ? "已观测下界 " : ""}${BigInt(value).toLocaleString("zh-CN")}`
                }
              >
                <Text component="span" inherit c="dimmed">
                  {label}
                </Text>{" "}
                <ContinuousValue
                  text={
                    value == null
                      ? "—"
                      : `${row.tokenUsageIncomplete ? "≥ " : ""}${compactKeyTokens(value)}`
                  }
                />
              </Text>
            ))}
          </Stack>
        );
      },
    },
    {
      id: "images",
      title: "生图",
      width: "11%",
      render: (row) => (
        <Text
          size="sm"
          title={
            row.images == null
              ? "无图片产出观测"
              : BigInt(row.images).toLocaleString("zh-CN")
          }
        >
          <ContinuousValue
            text={row.images == null ? "—" : compactCount(row.images)}
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
            size="h5"
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
    </Paper>
  );
}
