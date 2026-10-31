import { Paper, Title, Text, Stack, Button } from "@mantine/core";
import type { UseQueryResult } from "@tanstack/react-query";
import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
import { request } from "../../shared/management";
import { z } from "../../shared/schema";
import { ErrorState } from "../../shared/ui/States";
import { money } from "../../shared/presentation";

const numeric = z.string().regex(/^(0|[1-9][0-9]*)$/);
const schema = z.object({
  capacities: z.array(
    z.object({
      name: z.string(),
      current: numeric.nullable(),
      limit: numeric,
      blocking: z.boolean(),
    }),
  ),
  accounts: z
    .array(
      z.object({
        id: z.string(),
        current: z.number(),
        peak24Hours: z.number(),
        limit: z.number(),
        blocking: z.boolean(),
      }),
    )
    .max(64),
  unknownReconciliation: z.object({
    count: z.number().int().nonnegative(),
    beforeUnixSeconds: z.number().int().nonnegative(),
    periodSeconds: z.number(),
  }),
});
export async function fetchHeadroom(signal: AbortSignal) {
  return schema.parse(await request("/api/usage/headroom", { signal }));
}
export function CapacityPanel({
  query,
  accounts,
  onRelease,
}: {
  query: UseQueryResult<z.infer<typeof schema>, Error>;
  accounts?: readonly AccountName[];
  onRelease: (before: number, count: number) => void;
}) {
  return (
    <Paper withBorder p="md" component="section" aria-label="容量余量">
      <Title order={3} size="h4" mb="sm">
        容量余量
      </Title>
      {query.isError ? (
        <ErrorState retry={() => void query.refetch()}>
          余量读取失败，未将缺失值记为零。
        </ErrorState>
      ) : !query.data ? (
        <Text>正在读取余量</Text>
      ) : (
        <Stack gap="xs">
          {query.data.capacities.map((value) => (
            <Text size="sm" key={value.name}>
              {value.name === "daily_requests"
                ? "今日请求"
                : value.name === "daily_estimated_micros"
                  ? "今日估算费用"
                  : "明细行数"}
              ：
              {value.name === "daily_estimated_micros"
                ? money(value.current)
                : (value.current ?? "不可用")}{" "}
              /{" "}
              {value.name === "daily_estimated_micros"
                ? money(value.limit)
                : value.limit}
              （参考阈值，仅提醒）
            </Text>
          ))}
          {query.data.accounts.map((value) => (
            <Text size="sm" key={value.id}>
              {accountName(value.id, accounts)}：当前并发 {value.current} /{" "}
              {value.limit}，24 小时峰值 {value.peak24Hours}（并发上限会阻断）
            </Text>
          ))}
          <Text size="xs" c="dimmed">
            费用是已观测下界，未知部分未计入；存储水位见系统状态详情。
          </Text>
          <Text size="sm">
            {query.data.unknownReconciliation.count} 条待核对；核对期 24
            小时，期满关闭后用量仍为未知。
          </Text>
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
