import { useEffect, useState } from "react";
import {
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
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
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
  const [confirm, setConfirm] = useState<{
    account: api.Account;
    mode: api.AccountMode;
  } | null>(null);
  function changeMode(account: api.Account, mode: api.AccountMode) {
    if (mode === "enabled") state.setMode(account, mode);
    else setConfirm({ account, mode });
  }
  const [selected, setSelected] = useState<string | null>(null);
  const account = state.accounts.find((item) => item.id === selected);
  const blocked = state.busy || state.locked || !!state.flow;
  const overlay = !!account || !!state.flow || !!confirm;
  useEffect(() => {
    if (!overlay) return;
    document.body.classList.add("management-overlay-open");
    return () => document.body.classList.remove("management-overlay-open");
  }, [overlay]);
  function begin(value: api.Account | null) {
    setSelected(null);
    void state.begin(value);
  }
  if (state.checking) return <Text role="status">正在检查管理会话…</Text>;
  return (
    <section className={styles.workspace} aria-labelledby="accounts-heading">
      <Group justify="space-between" mb="xl">
        <Title id="accounts-heading" order={1}>
          订阅账号
        </Title>
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
        <Alert color="red" role="alert" mb="md">
          {state.error}
        </Alert>
      )}
      {state.notice && !state.flow && !account && (
        <Alert
          color={state.noticeTone === "warning" ? "yellow" : "green"}
          className={
            state.noticeTone === "warning" ? "warning-banner" : undefined
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
      {!state.configured ? (
        <Paper withBorder p="xl">
          <Title order={2}>账号接入尚未开启</Title>
          <Text c="dimmed" mt="sm">
            请由服务维护者完成账号安全配置，再重新读取。
          </Text>
        </Paper>
      ) : !state.accounts.length ? (
        <Paper withBorder p="xl">
          <Text c="dimmed">
            还没有订阅账号。点击上方“发起账号授权”接入第一个账号。
          </Text>
        </Paper>
      ) : (
        <Paper withBorder p="md">
          <div className="responsive-table">
            <Table verticalSpacing="lg" highlightOnHover>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>账号</Table.Th>
                  <Table.Th>使用策略</Table.Th>
                  <Table.Th>授权</Table.Th>
                  <Table.Th>额度与健康</Table.Th>
                  <Table.Th>操作</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
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
                                (summary.quota.state === "stale" ||
                                  (Math.max(state.clock, performance.now()) -
                                    summary.receivedAt) /
                                    1000 >=
                                    summary.quota.freshForSeconds)
                              ? "额度观测已陈旧"
                              : null;
                  return (
                    <Table.Tr key={item.id}>
                      <Table.Td data-label="账号">
                        <Text fw={600} size="sm" className={styles.id}>
                          {item.displayName ?? item.id}
                        </Text>
                        {item.displayName && (
                          <Text size="xs" c="dimmed" className={styles.id}>
                            {item.id}
                          </Text>
                        )}
                      </Table.Td>
                      <Table.Td data-label="使用策略">
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
                      </Table.Td>
                      <Table.Td data-label="授权">
                        <Badge
                          variant="outline"
                          color={
                            item.authorization === "ready" ? "green" : "yellow"
                          }
                        >
                          {authorization[item.authorization]}
                        </Badge>
                      </Table.Td>
                      <Table.Td data-label="额度与健康">
                        <QuotaWindowBar
                          title="主窗口"
                          value={quota?.primary ?? null}
                        />
                        <QuotaWindowBar
                          title="次窗口"
                          value={quota?.secondary ?? null}
                        />
                        <Text size="xs" c="dimmed">
                          {!summary
                            ? "尚无观测"
                            : summary.quota.state === "unavailable"
                              ? "额度不可用"
                              : summary.quota.state === "stale" ||
                                  (Math.max(state.clock, performance.now()) -
                                    summary.receivedAt) /
                                    1000 >=
                                    summary.quota.freshForSeconds
                                ? "额度观测已陈旧"
                                : "额度观测新鲜"}
                          {summary?.quota.failure ? " · 最近读取失败" : ""}
                        </Text>
                        {attention && (
                          <Text size="xs" c="orange">
                            {attention}
                          </Text>
                        )}
                      </Table.Td>
                      <Table.Td data-label="操作">
                        <Group gap="xs" wrap="nowrap">
                          <Button
                            variant="subtle"
                            size="xs"
                            onClick={() => setSelected(item.id)}
                          >
                            额度与健康详情
                          </Button>
                          <Button
                            variant="subtle"
                            size="xs"
                            color={item.mode === "disabled" ? "green" : "red"}
                            disabled={blocked}
                            onClick={() =>
                              changeMode(
                                item,
                                item.mode === "disabled"
                                  ? "enabled"
                                  : "disabled",
                              )
                            }
                          >
                            {item.mode === "disabled" ? "启用" : "禁用"}
                          </Button>
                        </Group>
                      </Table.Td>
                    </Table.Tr>
                  );
                })}
              </Table.Tbody>
            </Table>
          </div>
        </Paper>
      )}
      <Modal
        opened={!!confirm}
        onClose={() => {
          if (!state.busy) setConfirm(null);
        }}
        title={confirm?.mode === "draining" ? "排空账号" : "禁用账号"}
        lockScroll={false}
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
          <Text>{confirm?.account.id}</Text>
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
        opened={!!account && !state.flow && !confirm}
        onClose={() => setSelected(null)}
        title="账号详情"
        position="right"
        size="lg"
        lockScroll={false}
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
                  state.noticeTone === "warning" ? "warning-banner" : undefined
                }
                role="status"
              >
                {state.notice}
              </Alert>
            )}
            <Button
              variant="default"
              disabled={state.busy}
              onClick={() => void state.reread()}
            >
              重新读取账号
            </Button>
            <div>
              <Text fw={600} className={styles.id}>
                {account.id}
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
              <Group gap="xs">
                {(["enabled", "draining", "disabled"] as const).map((mode) => (
                  <Button
                    key={mode}
                    size="xs"
                    variant={account.mode === mode ? "filled" : "default"}
                    disabled={blocked || account.mode === mode}
                    onClick={() => changeMode(account, mode)}
                  >
                    {mode === "enabled"
                      ? "启用"
                      : mode === "draining"
                        ? "排空"
                        : "禁用"}
                  </Button>
                ))}
              </Group>
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
                <Button
                  variant="default"
                  disabled={blocked || account.authorization === "refreshing"}
                  onClick={() => begin(account)}
                >
                  重新授权
                </Button>
              </Group>
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
        lockScroll={false}
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
