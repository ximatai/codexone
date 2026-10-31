import {
  accountName,
  credentialExpiry,
} from "../../shared/account-presentation";
import { ConfirmModal } from "../../shared/ui/ConfirmModal";
import { useManagedMutation } from "../../shared/useManagedMutation";
import { releaseUnknown, type AttentionItem } from "./attention-api";
import { useQueryClient } from "@tanstack/react-query";
import { AttentionPanel } from "./AttentionPanel";
import { attentionQueryKey, fetchAttention } from "./attention-api";
import { quotaStale } from "../account-management/quota";
import { useOverviewRefresh } from "./useOverviewRefresh";
import { ActivityOverview } from "./ActivityOverview";
import styles from "./overview.module.css";
import { EmptyState } from "../../shared/ui/States";
import { useQuery } from "@tanstack/react-query";
import {
  Drawer,
  Alert,
  Button,
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
import { terms } from "../../shared/presentation";

import { z } from "../../shared/schema";

const backupSchema = z.object({
  enabled: z.boolean(),
  lastSuccessUnixSeconds: z.number().nullable().optional(),
  retainedCount: z.number().int().nonnegative(),
});
function backupTime(backup: z.infer<typeof backupSchema> | undefined) {
  if (!backup) return "未提供";
  if (!backup.enabled) return "未启用";
  if (!backup.lastSuccessUnixSeconds) return "尚无成功备份";
  return new Date(backup.lastSuccessUnixSeconds * 1000).toLocaleString();
}
async function fetchStorage(
  signal: AbortSignal,
): Promise<
  Record<string, unknown> & { backup?: z.infer<typeof backupSchema> }
> {
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
  return {
    ...value,
    backup: value.backup == null ? undefined : backupSchema.parse(value.backup),
  };
}
export function AdminOverview() {
  const owner = useManagementSession();
  const refresh = useOverviewRefresh();
  const client = useQueryClient();
  const [release, setRelease] = useState<{
    before: number;
    count: number;
  } | null>(null);
  const mutation = useManagedMutation({
    scope: "executions",
    invalidate: [["overview"], ["usage"]],
    refresh: async (signal) => {
      try {
        const report = await fetchAttention(signal);
        client.setQueryData(attentionQueryKey, report);
        return true;
      } catch {
        return false;
      }
    },
    onFailure: () => setRelease(null),
    errorMessage: (error) =>
      error instanceof ManagementError && error.status === 409
        ? "待核对数量已变化；请先确认提醒已刷新，再重新核对释放。"
        : undefined,
  });
  const polling = {
    refetchInterval: refresh.interval,
    staleTime: 15000,
    refetchOnWindowFocus: true,
  };
  const [clock, setClock] = useState(() => performance.now());
  useEffect(() => {
    const timer = window.setInterval(() => setClock(performance.now()), 15000);
    return () => window.clearInterval(timer);
  }, []);
  const [params, setParams] = useSearchParams();
  const overlay = !!owner.session && params.get("storage") === "details";
  const protocolOverlay =
    !!owner.session && params.get("protocol") === "details";
  const accounts = useQuery({
    queryKey: ["overview", "accounts"],
    queryFn: ({ signal }) => fetchAccounts(signal),
    enabled: !!owner.session,
    ...polling,
  });
  const usage = useQuery({
    queryKey: ["overview", "key-usage"],
    queryFn: ({ signal }) => fetchKeyUsage(signal),
    enabled: !!owner.session,
    ...polling,
  });
  const storage = useQuery({
    queryKey: ["overview", "storage"],
    queryFn: ({ signal }) => fetchStorage(signal),
    enabled: !!owner.session,
    ...polling,
  });
  const attention = useQuery({
    queryKey: attentionQueryKey,
    queryFn: ({ signal }) => fetchAttention(signal),
    enabled: !!owner.session,
    ...polling,
  });
  const unauthorized = [
    accounts.error,
    usage.error,
    storage.error,
    attention.error,
  ].some((error) => error instanceof ManagementError && error.status === 401);
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
  return (
    <Stack mb="xl" aria-label="管理概览">
      {owner.locked("executions") && !mutation.busy && (
        <Alert color="yellow" role="alert">
          上次释放结果尚未确认，请先刷新提醒核对后再操作。
          <Button
            size="xs"
            variant="light"
            ml="sm"
            onClick={() => {
              void attention.refetch().then((result) => {
                if (result.isSuccess) owner.lock("executions", false);
              });
            }}
          >
            刷新并核对释放结果
          </Button>
        </Alert>
      )}
      <ActivityOverview
        refresh={refresh}
        accounts={accounts.data}
        extraQueries={[
          { ...accounts, source: "订阅账号" },
          { ...usage, source: "Key 用量摘要" },
          { ...storage, source: "存储状态" },
          { ...attention, source: "需要处理提醒" },
        ]}
        attention={
          <AttentionPanel
            aggregateErrors
            items={attention.data?.items}
            accounts={accounts.data}
            release={(item: AttentionItem) => {
              const count = item.detail.count;
              if (
                typeof count === "number" &&
                Number.isSafeInteger(count) &&
                count >= 0
              )
                setRelease({ before: Math.floor(Date.now() / 1000), count });
            }}
            loading={attention.isPending}
            error={attention.isError}
            retry={() => void attention.refetch()}
          />
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
                      <Anchor
                        component={Link}
                        to={`/accounts?target=${encodeURIComponent(account.id)}`}
                      >
                        {accountName(account.id, [], account.displayName)}
                      </Anchor>
                      <Text size="xs" c="dimmed">
                        {credentialExpiry(account.accessExpiresAtUnixSeconds)}
                      </Text>
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
                      <Text size="xs" c="orange">
                        {!quota || quota.state === "unavailable"
                          ? "额度不可用"
                          : quotaStale(
                                account.observability!,
                                Math.max(clock, performance.now()),
                              )
                            ? "额度观测已陈旧"
                            : ""}
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
              <Stack gap="xs">
                {[
                  {
                    label: "可用账号",
                    value: `${available ?? "—"} · 授权异常 ${abnormal ?? "—"}`,
                    to: "/accounts",
                    good: available != null && available > 0 && abnormal === 0,
                  },
                  {
                    label: terms.pending,
                    value: String(total("pending")),
                    to: todayUsage,
                    good: total("pending") === 0,
                  },
                  {
                    label: "存储与准入",
                    value: storage.data
                      ? storage.data.admissionAllowed
                        ? "允许准入"
                        : "暂停准入"
                      : "不可用",
                    to: "/?storage=details",
                    good: !!storage.data?.admissionAllowed,
                  },
                  {
                    label: "可选工作",
                    value: storage.data
                      ? storage.data.optionalWorkAllowed
                        ? "统计可用"
                        : "可选工作暂停"
                      : "不可用",
                    to: "/?storage=details",
                    good: !!storage.data?.optionalWorkAllowed,
                  },
                  {
                    label: "最近备份",
                    value: backupTime(storage.data?.backup),
                    to: "/?storage=details",
                    good:
                      !!storage.data?.backup?.enabled &&
                      !!storage.data.backup.lastSuccessUnixSeconds &&
                      storage.data.backup.lastSuccessUnixSeconds <=
                        Date.now() / 1000 &&
                      Date.now() / 1000 -
                        storage.data.backup.lastSuccessUnixSeconds <=
                        36 * 3600,
                  },
                ].map((row) => (
                  <Anchor
                    key={row.label}
                    component={Link}
                    to={row.to}
                    className={styles.statusRow}
                  >
                    <Text size="sm">{row.label}</Text>
                    <Text size="sm">
                      <span
                        style={{
                          color: row.good
                            ? "var(--mantine-color-green-7)"
                            : "var(--mantine-color-orange-7)",
                        }}
                      >
                        ●
                      </span>{" "}
                      {row.value} ›
                    </Text>
                  </Anchor>
                ))}
              </Stack>
            </Paper>
          </>
        }
      />
      <ConfirmModal
        opened={!!release}
        title="核对并释放待核对执行"
        busy={mutation.busy}
        disabled={mutation.busy || owner.locked("executions")}
        close={() => setRelease(null)}
        label="确认释放"
        confirm={() => {
          if (!release) return;
          const snapshot = release;
          void mutation
            .run(async (csrf, signal) => {
              await releaseUnknown(
                snapshot.before,
                snapshot.count,
                csrf,
                signal,
              );
            }, "已释放容量占用，统计仍显示用量未知。")
            .then((success) => {
              if (success) setRelease(null);
            });
        }}
      >
        <Text>
          将释放 {release?.count}{" "}
          条待核对执行。这些请求的真实用量无法得知；释放只解除容量占用，统计中仍显示用量未知。
        </Text>
      </ConfirmModal>
      <Drawer
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={protocolOverlay || undefined}
        opened={protocolOverlay}
        onClose={() => setParams({})}
        title="客户端协议扩展"
        position="right"
        closeButtonProps={{ "aria-label": "关闭" }}
      >
        <Stack>
          <Text size="sm">
            本进程启动以来观察到的未知协议名称；仅记录名称，重启后清空。请结合客户端版本核对兼容性。
          </Text>
          {attention.data?.items
            .filter((item) => item.kind === "client_protocol_extension")
            .map((item, index) => (
              <Stack key={index} gap="xs">
                <Text size="sm" className="wrap-anywhere">
                  {item.subjectName ?? item.subjectID ?? "未知名称"}
                </Text>
                <Text size="xs" c="dimmed">
                  首次出现：
                  {item.sinceUnixSeconds == null
                    ? "不可用"
                    : new Date(item.sinceUnixSeconds * 1000).toLocaleString()}
                </Text>
                {item.detail.overflow === true && (
                  <Text size="sm" c="orange">
                    名称集合已达上限，后续新名称未记录。
                  </Text>
                )}
              </Stack>
            ))}
        </Stack>
      </Drawer>
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
          <Text>最近成功备份：{backupTime(storage.data?.backup)}</Text>
          <Text>
            保留备份：{storage.data?.backup?.retainedCount ?? "未提供"}
          </Text>
          <Text size="sm">
            存储压力影响新请求与可选工作；已准入请求仍按持久账本收尾。
          </Text>
        </Stack>
      </Drawer>
    </Stack>
  );
}
