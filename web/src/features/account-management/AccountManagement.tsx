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
  CopyButton,
  ActionIcon,
  Tooltip,
  Menu,
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
  SegmentedControl,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { IconDots, IconRefresh } from "@tabler/icons-react";
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
export function AccountManagement() {
  const state = useAccounts();
  const [params, setParams] = useSearchParams();
  const [confirm, setConfirm] = useState<{
    account: api.Account;
    mode: api.AccountMode;
  } | null>(null);
  function changeMode(account: api.Account, mode: api.AccountMode) {
    if (mode === "enabled") state.setMode(account, mode);
    else setConfirm({ account, mode });
  }
  const selected = params.get("target");
  function setSelected(id: string | null) {
    setParams(
      (previous) => {
        const next = new URLSearchParams(previous);
        if (id) next.set("target", id);
        else next.delete("target");
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
  if (state.checking) return <LoadingState>正在检查管理会话…</LoadingState>;
  return (
    <section className={styles.workspace} aria-labelledby="accounts-heading">
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
        <ErrorState retry={() => void state.reread()}>{state.error}</ErrorState>
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
              <Paper withBorder p="lg" key={item.id}>
                <Group justify="space-between" align="start" mb="md">
                  <div aria-label="账号" className={styles.cardIdentity}>
                    <Text fw={700} size="xl" className="wrap-anywhere">
                      {accountName(item.id, [], item.displayName)}
                    </Text>
                    <Text size="xs" c="dimmed">
                      {credentialExpiry(item.accessExpiresAtUnixSeconds)}
                    </Text>
                    {!item.displayName && (
                      <Text size="xs" c="dimmed">
                        可在账号详情中设置名称
                      </Text>
                    )}
                    {item.displayName && (
                      <Text size="xs" c="dimmed" className={styles.id}>
                        {item.id}
                      </Text>
                    )}
                  </div>
                  <div aria-label="使用策略">
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
                  </div>
                </Group>
                <div className={styles.cardSection} aria-label="额度与健康">
                  <div className={styles.windows}>
                    <QuotaWindowBar
                      title="主窗口"
                      value={quota?.primary ?? null}
                    />
                    <QuotaWindowBar
                      title="次窗口"
                      value={quota?.secondary ?? null}
                    />
                  </div>
                  {attention && (
                    <Text size="xs" c="orange">
                      {attention}
                    </Text>
                  )}
                </div>
                <div className={styles.cardSection} aria-label="操作">
                  <Group gap="xs" wrap="nowrap">
                    <Button
                      variant="subtle"
                      size="xs"
                      onClick={() => setSelected(item.id)}
                    >
                      额度与健康详情
                    </Button>
                    {item.mode === "disabled" ? (
                      <Button
                        variant="subtle"
                        size="xs"
                        disabled={blocked}
                        onClick={() => changeMode(item, "enabled")}
                      >
                        启用
                      </Button>
                    ) : (
                      <Menu position="bottom-end">
                        <Menu.Target>
                          <ActionIcon
                            variant="default"
                            aria-label={`${accountName(item.id, [], item.displayName)} 更多操作`}
                          >
                            <IconDots size={17} />
                          </ActionIcon>
                        </Menu.Target>
                        <Menu.Dropdown>
                          <Menu.Item
                            color="red"
                            disabled={blocked}
                            onClick={() => changeMode(item, "disabled")}
                          >
                            禁用
                          </Menu.Item>
                        </Menu.Dropdown>
                      </Menu>
                    )}
                  </Group>
                </div>
              </Paper>
            );
          })}
        </div>
      )}
      <Modal
        zIndex={400}
        opened={!!confirm}
        onClose={() => {
          if (!state.busy) setConfirm(null);
        }}
        title={confirm?.mode === "draining" ? "排空账号" : "禁用账号"}
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!confirm || undefined}
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        <Stack>
          <Text>
            {confirm?.mode === "draining"
              ? "不再接收新的会话请求；已有身份关联的续接请求仍可派发，在途请求继续。"
              : "停止后续派发（包括续接）；已经派发的在途请求继续，不会主动取消。"}
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
              确认{confirm?.mode === "draining" ? "排空" : "禁用"}
            </Button>
          </Group>
        </Stack>
      </Modal>
      <Drawer
        opened={!!account && !state.flow}
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
        size="lg"
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={(!!account && !state.flow) || undefined}
        closeButtonProps={{ "aria-label": "关闭" }}
      >
        {account && (
          <Stack gap="xl">
            {state.error && (
              <Alert color="red" role="alert">
                {state.error}
              </Alert>
            )}
            {state.notice && (
              <Alert
                color={state.noticeTone === "warning" ? "yellow" : "green"}
                className={
                  state.noticeTone === "warning" ? styles.warning : undefined
                }
                role="status"
              >
                {state.notice}
              </Alert>
            )}

            <div>
              <Text fw={600} className={styles.id}>
                {accountName(account.id, [], account.displayName)}
              </Text>
              <Text size="xs" c="dimmed">
                凭证 v{account.credentialVersion} · 修订 {account.revision} ·
                接入于 {utc(account.createdAtUnixSeconds)}
              </Text>
            </div>
            <Text size="sm">
              访问凭证到期：{credentialTime(account.accessExpiresAtUnixSeconds)}
            </Text>
            <Text size="sm">
              最近凭证更新：
              {credentialTime(account.credentialUpdatedAtUnixSeconds)}
            </Text>
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
            <section aria-label="账号使用策略">
              <Title order={3} size="h5" mb="sm">
                使用策略
              </Title>
              <SegmentedControl
                value={account.mode}
                disabled={blocked}
                onChange={(mode) =>
                  changeMode(account, mode as api.AccountMode)
                }
                data={[
                  { value: "enabled", label: "启用" },
                  { value: "draining", label: "排空" },
                  { value: "disabled", label: "禁用" },
                ]}
              />
              <Text size="xs" c="dimmed" mt="xs">
                排空只保留已有身份关联；禁用停止后续派发。
              </Text>
            </section>
            <section aria-label="账号授权">
              <Title order={3} size="h5" mb="sm">
                授权
              </Title>
              <Text size="sm" mb="sm">
                {authorization[account.authorization]}
              </Text>
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
                  刷新授权
                </Button>
              </Group>
            </section>
            <section aria-label="危险操作">
              <Title order={3} size="h5" mb="sm">
                危险操作
              </Title>
              <Text size="sm" c="dimmed" mb="sm">
                重新登录并替换账号授权；刷新授权仅更新现有凭证。
              </Text>
              <Button
                color="red"
                variant="outline"
                disabled={blocked || account.authorization === "refreshing"}
                onClick={() => begin(account)}
              >
                重新授权
              </Button>
            </section>
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
                  (result) => ({
                    text: observationNotice(result),
                    warning:
                      result.quota.failure !== null ||
                      result.quota.state === "unavailable",
                  }),
                )
              }
            />
          </Stack>
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
        description="仅管理员可见，最多 64 个字符；清除后显示账号标识。"
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
        >
          保存显示名
        </Button>
        <Button
          variant="default"
          disabled={disabled || !account.displayName}
          onClick={() => void save(null)}
        >
          清除显示名
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
