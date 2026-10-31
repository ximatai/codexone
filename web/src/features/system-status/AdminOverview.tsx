import { ActivityOverview } from "./ActivityOverview";
import styles from "./overview.module.css";
import { PageHeader } from "../../shared/ui/PageHeader";
import { EmptyState, ErrorState } from "../../shared/ui/States";
import { useQuery } from "@tanstack/react-query";
import {
  Drawer,
  Anchor,
  Paper,
  Stack,
  Text,
  Title,
  Skeleton,
} from "@mantine/core";
import { Link, useSearchParams } from "react-router";
import { useEffect, useState } from "react";
import { useManagementSession } from "../../shared/session";
import { ManagementError, request } from "../../shared/management";
import { fetchAccounts } from "../account-management/api";
import { fetchKeyUsage } from "../usage/api";
import { QuotaWindowBar } from "../account-management/QuotaWindowBar";
import { money, terms, estimateNote } from "../../shared/presentation";

async function fetchStorage(signal: AbortSignal) {
  const value = (await request("/api/runtime/storage", { signal })) as Record<
    string,
    unknown
  >;
  if (
    typeof value.admissionAllowed !== "boolean" ||
    typeof value.optionalWorkAllowed !== "boolean" ||
    typeof value.pressure !== "string"
  )
    throw new Error("invalid storage response");
  return value;
}
export function AdminOverview() {
  const owner = useManagementSession();
  const [clock, setClock] = useState(() => performance.now());
  useEffect(() => {
    const timer = window.setInterval(() => setClock(performance.now()), 15000);
    return () => window.clearInterval(timer);
  }, []);
  const [params, setParams] = useSearchParams();
  const overlay = !!owner.session && params.get("storage") === "details";
  const accounts = useQuery({
    queryKey: ["overview", "accounts"],
    queryFn: ({ signal }) => fetchAccounts(signal),
    enabled: !!owner.session,
  });
  const usage = useQuery({
    queryKey: ["overview", "key-usage"],
    queryFn: ({ signal }) => fetchKeyUsage(signal),
    enabled: !!owner.session,
  });
  const storage = useQuery({
    queryKey: ["overview", "storage"],
    queryFn: ({ signal }) => fetchStorage(signal),
    enabled: !!owner.session,
  });
  const unauthorized = [accounts.error, usage.error, storage.error].some(
    (error) => error instanceof ManagementError && error.status === 401,
  );
  useEffect(() => {
    if (unauthorized) owner.invalidate();
  }, [unauthorized, owner]);
  if (!owner.session) return null;
  const today = new Date().toISOString().slice(0, 10);
  const todayUsage = `/usage?start=${today}&end=${today}`;
  const available = accounts.data?.filter(
    (account) =>
      account.mode === "enabled" &&
      account.authorization === "ready" &&
      !account.observability?.health.authenticationRejected &&
      !account.observability?.health.cooldownCount,
  ).length;
  const abnormal = accounts.data?.filter(
    (account) =>
      account.authorization !== "ready" ||
      account.observability?.health.authenticationRejected,
  ).length;
  function total(field: "admitted" | "failed" | "pending") {
    return usage.data?.reduce((sum, item) => sum + item[field], 0) ?? "—";
  }
  const knownCost = usage.data?.filter((item) => item.estimatedMicros !== null);
  const cost = knownCost?.length
    ? knownCost
        .reduce((sum, item) => sum + BigInt(item.estimatedMicros!), 0n)
        .toString()
    : null;
  return (
    <Stack mb="xl" aria-label="管理概览">
      <div className={styles.header}>
        <PageHeader
          title="今日运营概览"
          description={`UTC 当日 · ${estimateNote}；缺失用量保持不可用，Token 与费用为已观测下界。`}
        />
      </div>
      {(accounts.isError || usage.isError || storage.isError) && (
        <ErrorState
          retryLabel="重新读取概览"
          retry={() => {
            void accounts.refetch();
            void usage.refetch();
            void storage.refetch();
          }}
        >
          部分概览读取失败或未开启，未将缺失值记为零。
        </ErrorState>
      )}
      <ActivityOverview
        refreshOverview={() =>
          Promise.all([accounts.refetch(), usage.refetch(), storage.refetch()])
        }
        sidebar={
          <>
            <Paper withBorder p="md">
              <Title order={3} size="h4" mb="md">
                订阅额度
              </Title>
              {accounts.isPending && <Skeleton h={160} />}
              {accounts.data?.length === 0 && (
                <EmptyState>暂无订阅账号。</EmptyState>
              )}
              <Stack gap="md">
                {accounts.data?.map((account) => {
                  const quota = account.observability?.quota;
                  const base = quota?.limits.find(
                    (limit) => limit.id === "codex",
                  );
                  return (
                    <Stack gap="xs" key={account.id} className="wrap-anywhere">
                      <Anchor component={Link} to="/accounts">
                        {account.displayName ?? account.id}
                      </Anchor>
                      <QuotaWindowBar
                        title="主窗口"
                        value={base?.primary ?? null}
                      />
                      <QuotaWindowBar
                        title="次窗口"
                        value={base?.secondary ?? null}
                      />
                      <Text
                        size="xs"
                        c={
                          base?.limitReached || base?.allowed === false
                            ? "red"
                            : "dimmed"
                        }
                      >
                        {base?.limitReached || base?.allowed === false
                          ? "额度告警：上游报告受限"
                          : "窗口为上游观测，不是 Key 余额"}
                      </Text>
                      <Text size="xs">
                        {!quota || quota.state === "unavailable"
                          ? "额度不可用"
                          : quota.state === "stale" ||
                              (Math.max(clock, performance.now()) -
                                account.observability!.receivedAt) /
                                1000 >=
                                quota.freshForSeconds
                            ? "额度观测已陈旧"
                            : "最近读取的额度观测"}
                        {quota?.failure ? " · 最近读取失败" : ""}
                      </Text>
                    </Stack>
                  );
                })}
              </Stack>
            </Paper>
            <Paper withBorder p="md">
              <Title order={3} size="h4" mb="md">
                系统状态
              </Title>
              <Stack gap="sm">
                <Anchor component={Link} to="/accounts">
                  可用账号
                </Anchor>
                <Text>
                  {available ?? "—"} · 授权异常 {abnormal ?? "—"}
                </Text>
                <Text size="xs" c="dimmed">
                  允许使用且无已知健康阻断，实际准入仍会复核。
                </Text>
                <Anchor component={Link} to={todayUsage}>
                  今日请求 / 失败
                </Anchor>
                <Text>
                  {total("admitted")} / {total("failed")}
                </Text>
                <Text size="sm">费用：{money(cost)}</Text>
                <Anchor component={Link} to={todayUsage}>
                  {terms.pending}
                </Anchor>
                <Text>{total("pending")}</Text>
                <Anchor component={Link} to="/?storage=details">
                  存储与准入状态
                </Anchor>
                <Text>
                  {storage.data
                    ? storage.data.admissionAllowed
                      ? "允许准入"
                      : "暂停准入"
                    : "不可用"}
                </Text>
                <Text size="sm" c="dimmed">
                  {storage.data
                    ? storage.data.optionalWorkAllowed
                      ? "统计可用"
                      : "可选工作暂停"
                    : "尚无存储观测"}
                </Text>
              </Stack>
            </Paper>
          </>
        }
      />
      <Drawer
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={overlay || undefined}
        opened={overlay}
        onClose={() => setParams({})}
        title="存储与准入详情"
        position="right"
        size="md"
        closeButtonProps={{ "aria-label": "关闭" }}
      >
        <Stack>
          <Text>
            {storage.data?.admissionAllowed
              ? "允许新请求准入"
              : "新请求准入暂停或状态不可用"}
          </Text>
          <Text>
            {storage.data?.optionalWorkAllowed
              ? "统计等可选工作可用"
              : "可选工作暂停或状态不可用"}
          </Text>
          {(
            [
              ["availableBytes", "磁盘可用"],
              ["databaseBytes", "数据库"],
              ["walBytes", "WAL"],
              ["reserveBytes", "已分配结算储备"],
            ] as const
          ).map(([field, label]) => (
            <Text key={field}>
              {label}：
              {typeof storage.data?.[field] === "number"
                ? `${(Number(storage.data[field]) / 1048576).toFixed(1)} MiB`
                : "未提供"}
            </Text>
          ))}
          <Text size="sm">
            存储压力影响新请求与可选工作；已准入请求仍按持久账本收尾。
          </Text>
        </Stack>
      </Drawer>
    </Stack>
  );
}
