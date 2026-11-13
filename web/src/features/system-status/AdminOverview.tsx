import { PrivateName } from "../../shared/privacy-mask";
import { overviewQuery } from "./overview-source";
import { availabilityBlocker } from "./availability-blocker";
import { fetchStorage } from "./storage-api";
import { useOverviewLive } from "./useOverviewLive";
import { fetchSystemStatus } from "./api";
import { OverviewMotion } from "../../shared/ui/ContinuousValue";
import { fetchHeadroom } from "../../shared/governance-api";
import { AdministratorReminders } from "./AdministratorReminders";
import {
  accountName,
  credentialExpiry,
} from "../../shared/account-presentation";
import { localTime } from "../../shared/presentation";
import { attentionQueryKey, fetchAttention } from "./attention-api";
import { quotaStale } from "../account-management/quota";
import { useOverviewRefresh } from "./useOverviewRefresh";
import { ActivityOverview } from "./ActivityOverview";
import styles from "./overview.module.css";
import { EmptyState } from "../../shared/ui/States";
import { useQuery } from "@tanstack/react-query";
import {
  Drawer,
  Anchor,
  Paper,
  Stack,
  Text,
  Title,
  Skeleton,
  Tooltip,
} from "@mantine/core";
import { Link, useSearchParams } from "react-router";
import { lazy, Suspense, useEffect, useState } from "react";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { fetchAccounts } from "../account-management/api";
import { OverviewQuotaWindow } from "./OverviewQuotaWindow";
import { RuntimeResources } from "./RuntimeResources";

const InlineAccountDetails = lazy(() =>
  import("../account-management/AccountManagement").then((module) => ({
    default: module.AccountManagement,
  })),
);

function quotaLabel(seconds: number | null | undefined, fallback: string) {
  if (seconds === 18000) return "5 小时额度";
  if (seconds === 604800) return "每周额度";
  return seconds && seconds % 3600 === 0
    ? `${seconds / 3600} 小时额度`
    : fallback;
}
function backupTime(
  backup: Awaited<ReturnType<typeof fetchStorage>>["backup"],
) {
  if (!backup) return "未提供";
  if (!backup.enabled) return "未启用";
  if (!backup.lastSuccessUnixSeconds) return "尚无成功备份";
  return new Date(backup.lastSuccessUnixSeconds * 1000).toLocaleString();
}
export function AdminOverview() {
  const owner = useManagementSession();
  const baseRefresh = useOverviewRefresh();
  const live = useOverviewLive(baseRefresh.active);
  const refresh = {
    ...baseRefresh,
    interval: live.mode === "live" ? (false as const) : baseRefresh.interval,
  };
  const polling = {
    refetchInterval: refresh.interval,
    staleTime: 15000,
    refetchOnWindowFocus: baseRefresh.active && live.mode !== "live",
    refetchOnReconnect: baseRefresh.active && live.mode !== "live",
  };
  const [clock, setClock] = useState(() => performance.now());
  useEffect(() => {
    const timer = window.setInterval(() => setClock(performance.now()), 15000);
    return () => window.clearInterval(timer);
  }, []);
  const [params, setParams] = useSearchParams();
  const [accountDrawerMounted, setAccountDrawerMounted] = useState(() =>
    params.has("account"),
  );
  useEffect(() => {
    if (params.has("account")) setAccountDrawerMounted(true);
  }, [params]);
  const overlay = !!owner.session && params.get("storage") === "details";
  const system = overviewQuery(
    useQuery({
      queryKey: ["overview", "system"],
      queryFn: ({ signal }) => fetchSystemStatus(signal),
      enabled: !!owner.session,
      ...polling,
    }),
    live?.sources.system,
  );
  const accounts = overviewQuery(
    useQuery({
      queryKey: ["overview", "accounts"],
      queryFn: ({ signal }) => fetchAccounts(signal),
      enabled: !!owner.session,
      ...polling,
    }),
    live?.sources.accounts,
  );
  const storage = overviewQuery(
    useQuery({
      queryKey: ["overview", "storage"],
      queryFn: ({ signal }) => fetchStorage(signal),
      enabled: !!owner.session,
      ...polling,
    }),
    live?.sources.storage,
  );
  const attention = overviewQuery(
    useQuery({
      queryKey: attentionQueryKey,
      queryFn: ({ signal }) => fetchAttention(signal),
      enabled: !!owner.session,
      ...polling,
    }),
    live?.sources.attention,
  );
  const headroom = overviewQuery(
    useQuery({
      queryKey: ["overview", "headroom"],
      queryFn: ({ signal }) => fetchHeadroom(signal),
      enabled: !!owner.session,
      ...polling,
    }),
    live?.sources.headroom,
  );
  const unauthorized = [
    accounts.error,
    storage.error,
    attention.error,
    headroom.error,
  ].some((error) => error instanceof ManagementError && error.status === 401);
  useEffect(() => {
    if (unauthorized) owner.invalidate();
  }, [unauthorized, owner]);
  if (!owner.session) return null;
  const protocolItems = (attention.data?.items ?? [])
    .filter((item) => item.kind === "client_protocol_extension")
    .sort((a, b) => (b.sinceUnixSeconds ?? 0) - (a.sinceUnixSeconds ?? 0));
  const eligibleAccounts = accounts.data?.filter(
    (account) =>
      account.mode === "enabled" &&
      account.authorization === "ready" &&
      !account.observability?.health.authenticationRejected,
  );
  return (
    <OverviewMotion reset={live.reset}>
      <Stack mb="xl" aria-label="管理概览">
        <ActivityOverview
          refresh={refresh}
          live={live}
          accounts={accounts.data}
          extraQueries={[
            { ...system, source: "生成就绪" },
            { ...accounts, source: "订阅账号" },
            { ...headroom, source: "治理余量" },
            {
              ...storage,
              source: "存储状态",
              isError: storage.isError || storage.data?.pressure === "unknown",
            },
            {
              ...attention,
              source: "运行提醒",
              isError:
                attention.isError ||
                !!attention.data?.items.some(
                  (item) => item.kind === "attention_source_unavailable",
                ),
            },
          ]}
          sidebar={(outputTrend) => (
            <>
              <AdministratorReminders
                storage={storage.data}
                storageError={storage.isError}
                backupOverdue={attention.data?.items.find(
                  (item) => item.kind === "backup_stale",
                )}
                backupUnconfirmed={attention.isError}
                availability={availabilityBlocker({
                  ready: system.isError ? undefined : system.data?.ready,
                  accountCount: accounts.isError
                    ? undefined
                    : accounts.data?.length,
                  eligibleIDs: accounts.isError
                    ? undefined
                    : eligibleAccounts?.map((account) => account.id),
                  accountHeadroom: headroom.isError
                    ? undefined
                    : headroom.data?.accounts,
                  storageAllowed: storage.isError
                    ? undefined
                    : storage.data?.admissionAllowed,
                  capacities: headroom.isError
                    ? undefined
                    : headroom.data?.capacities,
                })}
              />
              <Paper withBorder p="md">
                <Title order={3} size="h5" mb="md">
                  订阅额度
                  {accounts.isError && (
                    <Text component="span" size="xs" c="orange">
                      {" "}
                      · 快照已陈旧
                    </Text>
                  )}
                </Title>
                {accounts.isPending && !accounts.isFetched && (
                  <Skeleton h={160} />
                )}
                {!accounts.data && accounts.isFetched && (
                  <Text size="sm" c="dimmed">
                    暂无额度数据
                  </Text>
                )}
                {accounts.data?.length === 0 && (
                  <EmptyState>暂无订阅账号。</EmptyState>
                )}
                <Stack gap="md">
                  {accounts.data?.map((account) => {
                    const quota = account.observability?.quota;
                    const base = quota?.limits.find(
                      (limit) => limit.id === "codex",
                    );
                    const needsAuth =
                      account.authorization !== "ready" ||
                      account.observability?.health.authenticationRejected;
                    const accountStatus =
                      account.mode === "disabled"
                        ? "已禁用"
                        : needsAuth
                          ? "需要重新授权"
                          : account.observability?.health.cooldownCount
                            ? "模型冷却"
                            : account.mode === "draining"
                              ? "排空中"
                              : null;
                    const expires = account.accessExpiresAtUnixSeconds;
                    const quotaStatus =
                      !quota || quota.state === "unavailable"
                        ? "额度不可用"
                        : quotaStale(
                              account.observability!,
                              Math.max(clock, performance.now()),
                            )
                          ? "额度待更新"
                          : !base?.primary && !base?.secondary
                            ? "额度未提供"
                            : null;
                    return (
                      <Stack
                        gap="xs"
                        key={account.id}
                        className="wrap-anywhere"
                      >
                        <div className={styles.quotaAccountHeader}>
                          <Anchor
                            component={Link}
                            to={`/?account=${encodeURIComponent(account.id)}`}
                          >
                            <PrivateName>
                              {accountName(account.id, [], account.displayName)}
                            </PrivateName>
                          </Anchor>
                          {expires != null && (
                            <Tooltip
                              label={`访问凭证到期时间 · ${localTime(expires)}`}
                              events={{
                                hover: true,
                                focus: true,
                                touch: false,
                              }}
                            >
                              <Text size="xs" c="dimmed" tabIndex={0}>
                                {credentialExpiry(expires).replace(
                                  /^访问凭证(?:约 )?/,
                                  "",
                                )}
                              </Text>
                            </Tooltip>
                          )}
                        </div>
                        {accountStatus && (
                          <Text
                            size="xs"
                            c={
                              account.mode !== "disabled" && needsAuth
                                ? "orange.8"
                                : "dimmed"
                            }
                          >
                            {accountStatus}
                          </Text>
                        )}
                        {(base?.primary || base?.secondary) && (
                          <div className={styles.quotaWindows}>
                            {base.primary && (
                              <OverviewQuotaWindow
                                accountID={account.id}
                                kind="primary"
                                observedAt={
                                  quota?.observedAtUnixSeconds ?? null
                                }
                                unavailable={Boolean(
                                  quotaStatus ||
                                  quota?.failure ||
                                  needsAuth ||
                                  account.mode === "disabled",
                                )}
                                title={quotaLabel(
                                  base.primary.durationSeconds,
                                  "主窗口",
                                )}
                                value={base.primary}
                              />
                            )}
                            {base.secondary && (
                              <OverviewQuotaWindow
                                accountID={account.id}
                                kind="secondary"
                                observedAt={
                                  quota?.observedAtUnixSeconds ?? null
                                }
                                unavailable={Boolean(
                                  quotaStatus ||
                                  quota?.failure ||
                                  needsAuth ||
                                  account.mode === "disabled",
                                )}
                                title={quotaLabel(
                                  base.secondary.durationSeconds,
                                  "次窗口",
                                )}
                                value={base.secondary}
                              />
                            )}
                          </div>
                        )}
                        {(base?.limitReached || base?.allowed === false) && (
                          <Text size="xs" c="red">
                            上游额度受限
                          </Text>
                        )}
                        {(quotaStatus || quota?.failure) && (
                          <Text size="xs" c="orange.8">
                            {[
                              quotaStatus,
                              quota?.failure ? "最近读取失败" : null,
                            ]
                              .filter(Boolean)
                              .join(" · ")}
                          </Text>
                        )}
                      </Stack>
                    );
                  })}
                </Stack>
              </Paper>
              {outputTrend}
              <RuntimeResources
                storage={storage.data}
                stale={
                  storage.isError ||
                  live.stale.some(([source]) => source === "storage")
                }
              />
              {protocolItems.length > 0 && (
                <Paper
                  withBorder
                  p="md"
                  component="section"
                  aria-labelledby="overview-protocol"
                >
                  <Stack gap="xs" align="stretch">
                    <Title order={3} size="h5" id="overview-protocol">
                      协议观测
                    </Title>
                    <Stack gap="xs">
                      {protocolItems.map((item) => (
                        <div
                          key={
                            item.subjectName ??
                            item.subjectID ??
                            item.sinceUnixSeconds
                          }
                        >
                          <Text size="sm" className="wrap-anywhere">
                            {item.subjectName ?? item.subjectID ?? "未知名称"}
                          </Text>
                          <Text size="xs" c="dimmed">
                            首次观测：
                            {item.sinceUnixSeconds == null
                              ? "不可用"
                              : localTime(item.sinceUnixSeconds)}
                          </Text>
                        </div>
                      ))}
                    </Stack>
                    {protocolItems.some(
                      (item) => item.detail.overflow === true,
                    ) && (
                      <Text size="xs" c="dimmed">
                        名称已达记录上限。
                      </Text>
                    )}
                  </Stack>
                </Paper>
              )}
            </>
          )}
        />
        {accountDrawerMounted && (
          <Suspense fallback={null}>
            <InlineAccountDetails embedded />
          </Suspense>
        )}
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
    </OverviewMotion>
  );
}
