import { useQuery } from "@tanstack/react-query";
import { fetchHeadroom } from "../../shared/governance-api";
import { QuotaPriming } from "./QuotaPriming";
import { ResetCredits } from "./ResetCredits";
import { authorizationFailureMessage } from "./authorization-failure";
import {
  accountName,
  credentialExpiry,
} from "../../shared/account-presentation";
import { EmptyState, ErrorState, LoadingState } from "../../shared/ui/States";
import { useState } from "react";
import { useSearchParams } from "react-router";
import { localTime } from "../../shared/presentation";
import {
  Tabs,
  Accordion,
  CopyButton,
  ActionIcon,
  Tooltip,
  Alert,
  Anchor,
  Badge,
  Button,
  Drawer,
  Group,
  Loader,
  Modal,
  Paper,
  PasswordInput,
  Stack,
  Radio,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { IconRefresh } from "@tabler/icons-react";
import { quotaStale } from "./quota";
import * as api from "./api";
import { AccountObservability, utc } from "./AccountObservability";
import { observeAccount, observationNotice } from "./observation-api";
import { useAccounts } from "./useAccounts";
import styles from "./accounts.module.css";
import {
  accountModes as modes,
  authorizations as authorization,
} from "../../shared/presentation";
import { QuotaWindowBar } from "./QuotaWindowBar";
export function AccountManagement({
  embedded = false,
}: {
  embedded?: boolean;
}) {
  const state = useAccounts();
  const [params, setParams] = useSearchParams();
  const [confirm, setConfirm] = useState<{
    account: api.Account;
    mode: "disabled";
  } | null>(null);
  function changeMode(account: api.Account, mode: "enabled" | "disabled") {
    if (mode === "enabled") state.setMode(account, mode);
    else setConfirm({ account, mode });
  }
  const targetParam = embedded ? "account" : "target";
  const selected = params.get(targetParam);
  function setSelected(id: string | null) {
    setParams(
      (previous) => {
        const next = new URLSearchParams(previous);
        if (id) next.set(targetParam, id);
        else next.delete(targetParam);
        return next;
      },
      { replace: true },
    );
  }
  const account = state.accounts.find((item) => item.id === selected);
  const blocked = state.busy || state.locked || !!state.flow;
  function begin(value: api.Account | null) {
    setSelected(null);
    void state.begin(value);
  }
  if (state.checking && !embedded)
    return <LoadingState>正在检查管理会话…</LoadingState>;
  return (
    <section
      className={embedded ? styles.overlayHost : styles.workspace}
      aria-labelledby={embedded ? undefined : "accounts-heading"}
    >
      {!embedded && (
        <>
          <Group justify="space-between" mb="xl">
            <div>
              <Title id="accounts-heading" order={1}>
                订阅账号
              </Title>
              <Text c="dimmed" size="sm" mt="xs">
                管理订阅账号、额度与执行策略。
              </Text>
            </div>
            <Group>
              {!state.flow && !account && (
                <Group justify="flex-end">
                  {" "}
                  <Button
                    variant="default"
                    disabled={state.busy}
                    onClick={() => void state.reread()}
                  >
                    重新读取账号
                  </Button>
                </Group>
              )}
              <Button
                disabled={
                  !state.configured || blocked || state.accounts.length >= 64
                }
                onClick={() => begin(null)}
              >
                发起账号授权
              </Button>
            </Group>
          </Group>
          {state.error && !state.flow && !account && (
            <ErrorState retry={() => void state.reread()}>
              {state.error}
            </ErrorState>
          )}
          {state.notice && !state.flow && !account && (
            <Alert
              color={state.noticeTone === "warning" ? "yellow" : "green"}
              className={
                state.noticeTone === "warning" ? styles.warning : undefined
              }
              role="status"
              mb="md"
            >
              {state.notice}
            </Alert>
          )}
          {state.busy && (
            <Group role="status" mb="md">
              <Loader size="xs" />
              <Text size="sm">正在处理账号操作…</Text>
            </Group>
          )}
          {state.error && state.readAt && (
            <Text size="sm" c="dimmed">
              上次成功读取：{localTime(state.readAt)}；当前快照可能已过时。
            </Text>
          )}
          {selected && state.readAt && !account && !state.error && (
            <Alert color="yellow">
              目标账号已不存在。
              <Button variant="subtle" onClick={() => setSelected(null)}>
                返回账号列表
              </Button>
            </Alert>
          )}
          {!state.readAt && state.error ? null : !state.configured ? (
            <Paper withBorder p="xl">
              <Title order={2}>账号接入尚未开启</Title>
              <Text c="dimmed" mt="sm">
                请由服务维护者完成账号安全配置，再重新读取。
              </Text>
            </Paper>
          ) : !state.accounts.length ? (
            <Paper withBorder p="xl">
              <EmptyState>
                还没有订阅账号。点击上方“发起账号授权”接入第一个账号。
              </EmptyState>
            </Paper>
          ) : (
            <div className={styles.cards}>
              {state.accounts.map((item) => {
                const summary = item.observability;
                const quota = summary?.quota.limits.find(
                  (limit) => limit.id === "codex",
                );
                const attention = summary?.health.authenticationRejected
                  ? "认证拒绝"
                  : summary?.health.cooldownCount
                    ? `${summary.health.cooldownCount} 个模型冷却`
                    : quota?.allowed === false || quota?.limitReached
                      ? "上游额度受限"
                      : summary?.quota.failure
                        ? "最近读取失败"
                        : !summary || summary.quota.state === "unavailable"
                          ? "额度不可用"
                          : summary &&
                              quotaStale(
                                summary,
                                Math.max(state.clock, performance.now()),
                              )
                            ? "额度观测已陈旧"
                            : null;
                return (
                  <Paper
                    withBorder
                    p="md"
                    className={styles.accountCard}
                    key={item.id}
                  >
                    <Group
                      className={styles.cardHeader}
                      justify="space-between"
                      align="start"
                      mb="sm"
                    >
                      <div aria-label="账号" className={styles.cardIdentity}>
                        <Text fw={700} size="xl" className="wrap-anywhere">
                          {accountName(item.id, [], item.displayName)}
                        </Text>
                        <Text size="xs" c="dimmed">
                          {credentialExpiry(item.accessExpiresAtUnixSeconds)}
                        </Text>
                      </div>
                      <Group
                        className={styles.cardActions}
                        gap="xs"
                        align="center"
                        wrap="nowrap"
                      >
                        <Group
                          className={styles.cardBadges}
                          gap={4}
                          wrap="nowrap"
                          aria-label="账号状态"
                        >
                          <Badge
                            variant="light"
                            color={
                              item.mode === "enabled"
                                ? "green"
                                : item.mode === "draining"
                                  ? "yellow"
                                  : "gray"
                            }
                          >
                            {modes[item.mode]}
                          </Badge>
                          <Badge
                            variant="light"
                            color={
                              item.authorization === "ready"
                                ? "green"
                                : item.authorization === "requires_auth"
                                  ? "red"
                                  : "yellow"
                            }
                          >
                            {authorization[item.authorization]}
                          </Badge>
                        </Group>
                        <Button
                          className={styles.cardDetails}
                          variant="subtle"
                          size="xs"
                          aria-label="额度与健康详情"
                          onClick={() => setSelected(item.id)}
                        >
                          查看详情
                        </Button>
                      </Group>
                    </Group>
                    <div className={styles.cardSection} aria-label="额度与健康">
                      <div className={styles.windows}>
                        <QuotaWindowBar
                          title="5 小时额度"
                          value={quota?.primary ?? null}
                        />
                        <QuotaWindowBar
                          title="每周额度"
                          value={quota?.secondary ?? null}
                        />
                      </div>
                      {attention && (
                        <Text size="xs" c="orange">
                          {attention}
                        </Text>
                      )}
                    </div>
                  </Paper>
                );
              })}
            </div>
          )}
        </>
      )}
      <Modal
        zIndex={400}
        opened={!!confirm}
        onClose={() => {
          if (!state.busy) setConfirm(null);
        }}
        title="禁用账号"
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!confirm || undefined}
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        <Stack>
          <Text>
            禁用后不再发送新请求，包括已有会话的后续请求；进行中的请求继续。
          </Text>
          <Text>
            {confirm &&
              accountName(confirm.account.id, [], confirm.account.displayName)}
          </Text>
          <Group justify="flex-end">
            <Button
              variant="default"
              disabled={state.busy}
              onClick={() => setConfirm(null)}
            >
              取消
            </Button>
            <Button
              color="red"
              disabled={blocked}
              onClick={() => {
                if (confirm) {
                  state.setMode(confirm.account, confirm.mode);
                  setConfirm(null);
                }
              }}
            >
              确认禁用
            </Button>
          </Group>
        </Stack>
      </Modal>
      <Drawer
        opened={(!!account || (embedded && !!selected)) && !state.flow}
        onClose={() => setSelected(null)}
        title={
          <Group component="span">
            <Text component="span" size="xl" fw={700}>
              账号详情
            </Text>
            <Tooltip label="重新读取账号">
              <ActionIcon
                variant="subtle"
                aria-label="重新读取账号"
                disabled={state.busy}
                onClick={() => void state.reread()}
              >
                <IconRefresh size={18} />
              </ActionIcon>
            </Tooltip>
          </Group>
        }
        position="right"
        size="min(640px, 100vw)"
        classNames={{
          content: styles.detailContent,
          header: styles.detailHeader,
          body: styles.detailBody,
        }}
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={
          ((!!account || (embedded && !!selected)) && !state.flow) || undefined
        }
        closeButtonProps={{ "aria-label": "关闭" }}
      >
        {embedded &&
          !account &&
          (state.checking ? (
            <LoadingState>正在读取账号详情…</LoadingState>
          ) : !state.configured ? (
            <Text>账号接入尚未开启，无法读取账号详情。</Text>
          ) : state.error ? (
            <ErrorState retry={() => void state.reread()}>
              {state.error}
            </ErrorState>
          ) : !state.readAt ? (
            <LoadingState>正在读取账号详情…</LoadingState>
          ) : (
            <Text>目标账号已不存在或不在当前账号列表中。</Text>
          ))}
        {account && (
          <AccountDetailPanels
            embedded={embedded}
            key={account.id}
            account={account}
            state={state}
            blocked={blocked}
            onChangeMode={changeMode}
            onBegin={begin}
          />
        )}
      </Drawer>
      <Drawer
        opened={!!state.flow}
        onClose={() => {
          if (!state.busy) void state.cancel();
        }}
        title={state.flow?.accountID ? "重新授权账号" : "接入订阅账号"}
        position="right"
        size="lg"
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!state.flow || undefined}
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        closeButtonProps={{ "aria-label": "关闭", disabled: state.busy }}
      >
        {state.flow && (
          <form onSubmit={(event) => void state.complete(event)}>
            <Stack gap="lg">
              {state.error && (
                <Alert color="red" role="alert">
                  {state.error}
                </Alert>
              )}
              <Button
                variant="default"
                disabled={state.busy}
                onClick={() => void state.reread()}
              >
                重新读取账号
              </Button>
              <Text size="sm">
                {state.flow.accountID
                  ? "重新授权保持账号身份与使用策略。"
                  : "新账号授权后默认禁用，核对后再启用。"}
              </Text>
              {state.flow.method === "device" ||
              state.flowStatus?.status === "failed" ? (
                <DeviceAuthorization state={state} />
              ) : state.flowStatus?.status === "pending" ? (
                <Text role="status">正在验证并保存授权…</Text>
              ) : (
                <>
                  <Anchor
                    href={state.flow.authorizationURL}
                    target="_blank"
                    rel="noopener noreferrer"
                    referrerPolicy="no-referrer"
                  >
                    1. 在新窗口打开授权页面 ↗
                  </Anchor>
                  <Text size="sm" c="dimmed">
                    登录后复制完整 localhost
                    回调地址。即使回调页无法连接，也可复制地址栏。剩余{" "}
                    {state.remaining} 秒。
                  </Text>
                  <PasswordInput
                    label="2. 粘贴完整回调地址"
                    aria-label="2. 粘贴完整回调地址"
                    autoComplete="off"
                    spellCheck={false}
                    maxLength={7000}
                    value={state.callback}
                    onChange={(event) =>
                      state.setCallback(event.currentTarget.value)
                    }
                    disabled={state.busy || state.locked}
                    required
                    visibilityToggleButtonProps={{
                      "aria-label": "显示或隐藏回调地址",
                    }}
                    description="含一次性授权码，提交或离开后清除，请勿分享。"
                  />
                  <Group justify="flex-end">
                    <Button
                      type="button"
                      variant="default"
                      disabled={state.busy || state.locked}
                      onClick={() => void state.cancel()}
                    >
                      取消本次授权
                    </Button>
                    <Button
                      type="submit"
                      disabled={
                        state.busy ||
                        state.locked ||
                        !state.callback.trim() ||
                        !state.remaining
                      }
                    >
                      3. 验证并保存
                    </Button>
                  </Group>
                </>
              )}
            </Stack>
          </form>
        )}
      </Drawer>
    </section>
  );
}

function AccountDetailPanels({
  embedded,
  account,
  state,
  blocked,
  onChangeMode,
  onBegin,
}: {
  embedded?: boolean;
  account: api.Account;
  state: ReturnType<typeof useAccounts>;
  blocked: boolean;
  onChangeMode: (account: api.Account, mode: "enabled" | "disabled") => void;
  onBegin: (account: api.Account) => void;
}) {
  const [tab, setTab] = useState<string | null>("overview");
  const [visited, setVisited] = useState(["overview"]);
  const [automation, setAutomation] = useState<string[]>([]);
  const [loaded, setLoaded] = useState<string[]>([]);
  const headroom = useQuery({
    queryKey: ["overview", "headroom"],
    queryFn: ({ signal }) => fetchHeadroom(signal),
    staleTime: 15000,
    enabled: !embedded,
    refetchInterval: embedded ? false : 15000,
    refetchOnWindowFocus: !embedded,
  });
  const capacity = headroom.data?.accounts.find(
    (value) => value.id === account.id,
  );
  return (
    <div className={styles.detailLayout}>
      <Stack gap={8} className={styles.detailIdentity}>
        <Text size="xl" fw={700} className="wrap-anywhere">
          {accountName(account.id, [], account.displayName)}
        </Text>
        <Group gap="xs">
          <Badge
            variant="light"
            color={account.mode === "enabled" ? "green" : "gray"}
          >
            {modes[account.mode]}
          </Badge>
          <Badge
            variant="light"
            color={account.authorization === "ready" ? "green" : "orange"}
          >
            {authorization[account.authorization]}
          </Badge>
        </Group>
        <Text size="xs" c="dimmed">
          {credentialExpiry(account.accessExpiresAtUnixSeconds)}
        </Text>
        {state.error && (
          <Alert color="red" role="alert">
            {state.error}
          </Alert>
        )}
        {state.notice && (
          <Alert
            color={state.noticeTone === "warning" ? "yellow" : "green"}
            role="status"
          >
            {state.notice}
          </Alert>
        )}
      </Stack>
      <Tabs
        value={tab}
        onChange={(value) => {
          setTab(value);
          if (value)
            setVisited((previous) =>
              previous.includes(value) ? previous : [...previous, value],
            );
        }}
        keepMounted
        keepMountedMode="display-none"
        classNames={{
          root: styles.detailTabs,
          list: styles.detailTabList,
          panel: styles.detailTabPanel,
        }}
      >
        <Tabs.List grow>
          <Tabs.Tab value="overview">概览</Tabs.Tab>
          <Tabs.Tab value="automation">自动化</Tabs.Tab>
          <Tabs.Tab value="settings">设置</Tabs.Tab>
        </Tabs.List>
        <Tabs.Panel value="overview">
          <Stack gap="md">
            <Paper withBorder p="sm">
              <Group justify="space-between">
                <Text size="sm">当前并发</Text>
                <Text fw={600}>
                  {capacity
                    ? `${capacity.current} / ${capacity.limit}`
                    : headroom.isPending
                      ? "读取中"
                      : "未提供"}
                </Text>
              </Group>
              <Text size="xs" c="dimmed">
                {capacity
                  ? `24 小时峰值 ${capacity.peak24Hours}`
                  : "没有可用的并发观测"}
                {headroom.isError ? " · 读取失败，保留已有快照" : ""}
              </Text>
            </Paper>
            <AccountObservability
              key={account.id}
              account={account}
              now={state.clock}
              disabled={blocked}
              inDetails
              onUnauthorized={state.invalidate}
              onObserve={() =>
                void state.mutation(
                  (csrf, signal) => observeAccount(account.id, csrf, signal),
                  observationNotice,
                )
              }
            />
          </Stack>
        </Tabs.Panel>
        <Tabs.Panel value="automation">
          {visited.includes("automation") && (
            <Stack gap="md">
              <Accordion
                keepMounted
                keepMountedMode="display-none"
                multiple
                value={automation}
                onChange={(values) => {
                  setAutomation(values);
                  setLoaded((previous) => [
                    ...new Set([...previous, ...values]),
                  ]);
                }}
              >
                <Accordion.Item value="reset">
                  <Accordion.Control>重置卡与到期前自动使用</Accordion.Control>
                  <Accordion.Panel>
                    {loaded.includes("reset") && (
                      <>
                        <ResetCredits
                          hideTitle
                          key={`reset-${account.id}`}
                          account={account}
                          disabled={blocked}
                          reloadToken={state.readAt}
                          mutation={state.mutation}
                          onUnauthorized={state.invalidate}
                        />
                      </>
                    )}
                  </Accordion.Panel>
                </Accordion.Item>
                <Accordion.Item value="priming">
                  <Accordion.Control>空闲窗口预热</Accordion.Control>
                  <Accordion.Panel>
                    {loaded.includes("priming") && (
                      <>
                        <QuotaPriming
                          hideTitle
                          key={`priming-${account.id}`}
                          account={account}
                          disabled={blocked}
                          reloadToken={state.readAt}
                          mutation={state.mutation}
                          onUnauthorized={state.invalidate}
                        />
                      </>
                    )}
                  </Accordion.Panel>
                </Accordion.Item>
              </Accordion>
            </Stack>
          )}
        </Tabs.Panel>
        <Tabs.Panel value="settings">
          {visited.includes("settings") && (
            <Stack gap="lg">
              <DisplayNameEditor
                key={`${account.id}-${account.revision}`}
                account={account}
                disabled={blocked}
                save={(name) =>
                  state.mutation(
                    (csrf, signal) =>
                      api.setDisplayName(account, name, csrf, signal),
                    "显示名已更新。",
                  )
                }
              />
              <section aria-label="账号状态">
                <Radio.Group
                  label="账号状态"
                  value={account.mode}
                  onChange={(mode) =>
                    onChangeMode(account, mode as "enabled" | "disabled")
                  }
                >
                  <Group mt="xs">
                    <Radio value="enabled" label="启用" disabled={blocked} />
                    <Radio value="disabled" label="禁用" disabled={blocked} />
                  </Group>
                </Radio.Group>
                {account.mode === "draining" && (
                  <Text size="sm" c="yellow.8" mt="sm">
                    当前仅允许已有会话继续，请选择启用或禁用。
                  </Text>
                )}
              </section>
              <section aria-label="账号授权">
                <Title order={3} size="h5" mb="sm">
                  登录凭证
                </Title>
                <Group>
                  <Button
                    variant="default"
                    disabled={blocked || account.authorization !== "ready"}
                    onClick={() =>
                      void state.mutation(
                        (csrf, signal) =>
                          api.refreshAccount(account, csrf, signal),
                        "授权刷新已完成。",
                      )
                    }
                  >
                    刷新登录凭证
                  </Button>
                </Group>
                <Text size="sm" c="dimmed" mt="md" mb="sm">
                  重新登录将替换现有授权。
                </Text>
                <Button
                  color="red"
                  variant="outline"
                  disabled={blocked || account.authorization === "refreshing"}
                  onClick={() => onBegin(account)}
                >
                  重新登录授权
                </Button>
              </section>

              <details className={styles.technical}>
                <summary>技术信息</summary>
                <Stack gap={6} mt="sm">
                  <Text size="sm" className="wrap-anywhere">
                    账号标识：{account.id}
                  </Text>
                  <Text size="xs">
                    凭证 v{account.credentialVersion} · 修订 {account.revision}
                  </Text>
                  <Text size="xs" title={utc(account.createdAtUnixSeconds)}>
                    接入于 {localTime(account.createdAtUnixSeconds)}
                  </Text>
                  <Text
                    size="xs"
                    title={utc(account.accessExpiresAtUnixSeconds)}
                  >
                    访问凭证到期：
                    {credentialTime(account.accessExpiresAtUnixSeconds)}
                  </Text>
                  <Text
                    size="xs"
                    title={utc(account.credentialUpdatedAtUnixSeconds)}
                  >
                    最近凭证更新：
                    {credentialTime(account.credentialUpdatedAtUnixSeconds)}
                  </Text>
                </Stack>
              </details>
            </Stack>
          )}
        </Tabs.Panel>
      </Tabs>
    </div>
  );
}

function DisplayNameEditor({
  account,
  disabled,
  save,
}: {
  account: api.Account;
  disabled: boolean;
  save: (name: string | null) => Promise<void>;
}) {
  const [name, setName] = useState(account.displayName ?? "");
  const trimmed = name.trim();
  const valid =
    [...trimmed].length <= 64 &&
    !/[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u.test(trimmed);
  return (
    <Stack gap="xs">
      <TextInput
        label="账号显示名"
        title="仅管理员可见，最多64个字符；清除后使用账号标识。"
        value={name}
        disabled={disabled}
        onChange={(event) => setName(event.currentTarget.value)}
        error={!valid ? "请输入最多 64 个可打印字符。" : undefined}
      />
      <Group>
        <Button
          disabled={
            disabled ||
            !valid ||
            !trimmed.length ||
            trimmed === (account.displayName ?? "")
          }
          onClick={() => void save(trimmed)}
          aria-label="保存显示名"
        >
          保存
        </Button>
        <Button
          variant="default"
          disabled={disabled || !account.displayName}
          onClick={() => void save(null)}
          aria-label="清除显示名"
        >
          清除
        </Button>
      </Group>
    </Stack>
  );
}

export function credentialTime(
  value: number | null | undefined,
  now = Date.now(),
): string {
  if (value == null) return "不可用";
  const seconds = Math.round((value * 1000 - now) / 1000);
  const absolute = Math.abs(seconds);
  const relative =
    absolute < 60
      ? "刚刚"
      : `约 ${Math.round(absolute / (absolute < 3600 ? 60 : absolute < 86400 ? 3600 : 86400))} ${absolute < 3600 ? "分钟" : absolute < 86400 ? "小时" : "天"}${seconds >= 0 ? "后" : "前"}`;
  return `${new Date(value * 1000).toLocaleString()}（${relative}）`;
}

function DeviceAuthorization({
  state,
}: {
  state: ReturnType<typeof useAccounts>;
}) {
  const result = state.flowStatus;
  const completed = state.accounts.find(
    (item) => item.id === result?.accountID,
  );
  const pending = !result || result.status === "pending";
  return (
    <Stack gap="md">
      {pending && (
        <>
          <Text size="sm">
            在验证页面登录自己的账号，输入下方设备码。请勿分享设备码。
          </Text>
          <TextInput
            label="设备码"
            value={state.flow?.userCode ?? ""}
            readOnly
            autoComplete="off"
          />
          <CopyButton value={state.flow?.userCode ?? ""}>
            {({ copied, copy }) => (
              <Button variant="light" onClick={copy}>
                {copied ? "已复制设备码" : "复制设备码"}
              </Button>
            )}
          </CopyButton>
          <Anchor
            href={state.flow?.verificationURL}
            target="_blank"
            rel="noopener noreferrer"
            referrerPolicy="no-referrer"
          >
            打开验证页面 ↗
          </Anchor>
          <CopyButton value={state.flow?.verificationURL ?? ""}>
            {({ copied, copy }) => (
              <Button variant="subtle" onClick={copy}>
                {copied ? "已复制验证链接" : "复制验证链接"}
              </Button>
            )}
          </CopyButton>
          <Text role="status">等待授权完成…剩余 {state.remaining} 秒。</Text>
        </>
      )}
      {result?.status === "completed" && (
        <>
          <Alert color="green" role="status">
            {state.flow?.accountID
              ? "重新授权已完成，账号身份与使用策略保持不变。"
              : "授权已验证并保存，新账号默认禁用。"}
          </Alert>
          {!state.flow?.accountID && completed?.mode === "disabled" && (
            <Button
              disabled={state.busy || state.locked}
              onClick={() => state.setMode(completed, "enabled")}
            >
              启用
            </Button>
          )}
          {!state.flow?.accountID && completed?.mode === "enabled" && (
            <Text>账号已启用。</Text>
          )}
        </>
      )}
      {result?.status === "failed" && (
        <Alert color="red" role="alert">
          {authorizationFailureMessage(result.failureCode)}
        </Alert>
      )}
      {result?.status === "expired" && (
        <Alert color="yellow" role="alert">
          授权流程已过期，请关闭后重新发起。
        </Alert>
      )}
      <Button variant="default" onClick={() => void state.cancel()}>
        {pending ? "取消本次授权" : "关闭授权结果"}
      </Button>
      {state.flow?.method === "device" && result?.status !== "completed" && (
        <Anchor
          component="button"
          type="button"
          disabled={state.busy || state.locked}
          onClick={() => void state.switchToCallback()}
        >
          改用浏览器回调方式
        </Anchor>
      )}
    </Stack>
  );
}
