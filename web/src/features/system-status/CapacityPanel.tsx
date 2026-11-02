import {
  Paper,
  Title,
  Text,
  Stack,
  Button,
  Group,
  Progress,
  Badge,
} from "@mantine/core";
import type { UseQueryResult } from "@tanstack/react-query";
import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
import type { Headroom } from "../../shared/governance-api";
export { fetchHeadroom } from "../../shared/governance-api";
import { compactMoney, compactCount } from "./overview-format";

export function CapacityPanel({
  query,
  accounts,
  onRelease,
  mergedAccounts = false,
  mergedMetrics = false,
}: {
  query: UseQueryResult<Headroom, Error>;
  accounts?: readonly AccountName[];
  mergedAccounts?: boolean;
  mergedMetrics?: boolean;
  onRelease: (before: number, count: number) => void;
}) {
  return (
    <Paper withBorder p="md" component="section" aria-label="资源使用">
      <Title order={3} size="h4" mb="sm">
        资源使用
      </Title>
      {query.isError ? (
        <Text c="dimmed">
          余量读取失败，请使用概览汇总重试；缺失值未记为零。
        </Text>
      ) : !query.data ? (
        <Text>正在读取余量</Text>
      ) : (
        <Stack gap="xs">
          {query.data.capacities
            .filter(
              (value) =>
                !mergedMetrics ||
                !["daily_requests", "daily_estimated_micros"].includes(
                  value.name,
                ),
            )
            .map((value) => {
              const cost = value.name === "daily_estimated_micros";
              const label =
                value.name === "daily_requests"
                  ? "今日请求"
                  : cost
                    ? "今日估算费用"
                    : "明细行数";
              const ratio =
                value.current === null || BigInt(value.limit) === 0n
                  ? null
                  : Number(
                      (BigInt(value.current) * 10000n) / BigInt(value.limit),
                    ) / 100;
              const format = (v: string | null) =>
                v === null
                  ? "不可用"
                  : cost
                    ? compactMoney(v)
                    : compactCount(v);
              return (
                <Stack key={value.name} gap={5}>
                  <Group justify="space-between" gap="xs">
                    <Text size="sm">{label}</Text>
                    <Badge
                      size="xs"
                      variant="light"
                      color={value.blocking ? "orange" : "gray"}
                    >
                      {value.blocking ? "阻断上限" : "参考阈值"}
                    </Badge>
                  </Group>
                  <Group justify="space-between" gap="xs">
                    <Text
                      size="sm"
                      fw={600}
                      title={`${value.current ?? "不可用"} / ${value.limit}${cost ? " micro USD" : ""}`}
                    >
                      {format(value.current)} / {format(value.limit)}
                    </Text>
                    <Text size="xs" c="dimmed">
                      {ratio === null ? "比例不可用" : `${ratio.toFixed(1)}%`}
                    </Text>
                  </Group>
                  <Progress
                    value={ratio === null ? 0 : Math.min(100, ratio)}
                    color={ratio !== null && ratio >= 100 ? "orange" : "brand"}
                    size={6}
                    aria-label={`${label}已用比例${ratio === null ? "不可用" : ` ${ratio.toFixed(1)}%`}`}
                  />
                </Stack>
              );
            })}
          {query.data.accounts.some(
            (value) =>
              !mergedAccounts || !accounts?.some((a) => a.id === value.id),
          ) && (
            <Text size="xs" fw={600} mt="xs">
              账号并发 · 达到上限将阻断
            </Text>
          )}
          {query.data.accounts
            .filter(
              (value) =>
                !mergedAccounts || !accounts?.some((a) => a.id === value.id),
            )
            .map((value) => (
              <Stack key={value.id} gap={5}>
                <Group justify="space-between" gap="xs" wrap="nowrap">
                  <Text
                    size="sm"
                    lineClamp={1}
                    title={accountName(value.id, accounts)}
                  >
                    {accountName(value.id, accounts)}
                  </Text>
                  <Text size="sm" fw={600} style={{ whiteSpace: "nowrap" }}>
                    {value.current} / {value.limit}
                  </Text>
                </Group>
                <Progress
                  value={
                    value.limit > 0
                      ? Math.min(100, (value.current / value.limit) * 100)
                      : 0
                  }
                  size={6}
                  color={value.current >= value.limit ? "orange" : "brand"}
                  aria-label={`${accountName(value.id, accounts)}并发占用`}
                />
                <Text size="xs" c="dimmed">
                  24 小时峰值 {value.peak24Hours}
                </Text>
              </Stack>
            ))}
          <Text
            size="sm"
            mt="xs"
          >{`待核对 ${compactCount(query.data.unknownReconciliation.count)} 条`}</Text>
          {query.data.unknownReconciliation.count > 0 && (
            <Button
              size="xs"
              variant="light"
              onClick={() =>
                onRelease(
                  query.data!.unknownReconciliation.beforeUnixSeconds,
                  query.data!.unknownReconciliation.count,
                )
              }
            >
              核对并释放
            </Button>
          )}
        </Stack>
      )}
    </Paper>
  );
}
