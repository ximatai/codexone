import { useEffect, useState } from "react";
import {
  Alert,
  Badge,
  Button,
  Drawer,
  Group,
  Menu,
  Modal,
  Paper,
  NativeSelect,
  Stack,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { Link } from "react-router";
import * as api from "./api";
import { KeyEditor } from "./KeyEditor";
import { useKeys } from "./useKeys";
import { useQuery } from "@tanstack/react-query";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { fetchKeyUsage } from "../usage/api";
import {
  money,
  localTime,
  timeTitle,
  estimateNote,
} from "../../shared/presentation";
export function KeyManagement() {
  const state = useKeys();
  const owner = useManagementSession();
  const [refresh, setRefresh] = useState(0);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("");
  const [expiring, setExpiring] = useState<api.ManagedKey | null>(null);
  const [disabling, setDisabling] = useState<api.ManagedKey | null>(null);
  const usage = useQuery({
    queryKey: ["key-usage", state.keys, refresh],
    queryFn: ({ signal }) => fetchKeyUsage(signal),
    enabled: !state.checking && !state.busy && !state.loading,
    retry: false,
  });
  useEffect(() => {
    if (usage.error instanceof ManagementError && usage.error.status === 401)
      owner.invalidate();
  }, [usage.error, owner]);
  const keys = state.keys
    .filter(
      (key) =>
        key.principal.toLowerCase().includes(search.toLowerCase()) &&
        (!status || key.enabled === (status === "enabled")),
    )
    .sort(
      (a, b) =>
        Number(b.enabled) - Number(a.enabled) ||
        a.principal.localeCompare(b.principal),
    );
  function toggle(key: api.ManagedKey) {
    return state.mutate(
      (csrf, signal) =>
        api.updateKey(key, !key.enabled, key.models, key.limits, csrf, signal),
      key.enabled ? "密钥已禁用。" : "密钥已启用。",
    );
  }
  const overlay =
    state.creating ||
    !!state.editing ||
    !!state.rotating ||
    !!state.created ||
    !!disabling ||
    !!expiring;
  useEffect(() => {
    if (!overlay) return;
    document.body.classList.add("management-overlay-open");
    return () => document.body.classList.remove("management-overlay-open");
  }, [overlay]);
  return (
    <section>
      <Group justify="space-between" mb="xl">
        <Title order={1}>访问密钥</Title>
        <Group>
          <Button
            variant="default"
            disabled={state.busy || state.loading}
            onClick={() => {
              state.reload();
              setRefresh((value) => value + 1);
            }}
          >
            {state.loading ? "正在刷新…" : "刷新列表"}
          </Button>
          <Button
            disabled={state.disabled}
            onClick={() => state.setCreating(true)}
          >
            创建密钥
          </Button>
        </Group>
      </Group>
      <Group mb="md">
        <TextInput
          label="搜索主体名"
          value={search}
          onChange={(e) => setSearch(e.currentTarget.value)}
        />
        <NativeSelect
          label="密钥状态"
          value={status}
          onChange={(e) => setStatus(e.currentTarget.value)}
          data={[
            { value: "", label: "全部状态" },
            { value: "enabled", label: "启用" },
            { value: "disabled", label: "禁用" },
          ]}
        />
      </Group>
      <Text size="xs" c="dimmed" mb="md">
        今日统计按 UTC · {estimateNote}。
        {usage.isError ? "今日摘要读取失败，请刷新列表重试。" : ""}
      </Text>
      {state.error && (
        <Alert role="alert" color="red" mb="md">
          {state.error}
        </Alert>
      )}
      {state.notice && (
        <Alert role="status" color="green" mb="md">
          {state.notice}
        </Alert>
      )}
      {state.checking ? (
        <p role="status">正在读取密钥…</p>
      ) : state.unavailable ? (
        <Alert>管理入口尚未启用</Alert>
      ) : (
        <Paper withBorder radius="md" p="md">
          <div className="responsive-table">
            <Table verticalSpacing="md" highlightOnHover>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>主体 / 标识</Table.Th>
                  <Table.Th>权限</Table.Th>
                  <Table.Th>状态</Table.Th>
                  <Table.Th>本地限制</Table.Th>
                  <Table.Th>今日 / 最近使用</Table.Th>
                  <Table.Th>操作</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {keys.map((key) => (
                  <Table.Tr key={key.id}>
                    <Table.Td data-label="主体 / 标识">
                      <Text fw={600}>{key.principal}</Text>
                      <Text
                        size="xs"
                        c="dimmed"
                        className="identifier"
                        title={key.id}
                      >
                        {key.id}
                      </Text>
                      <Text
                        size="xs"
                        c="dimmed"
                        title={timeTitle(key.createdAtUnixSeconds)}
                      >
                        创建：{localTime(key.createdAtUnixSeconds)}
                      </Text>
                    </Table.Td>
                    <Table.Td data-label="权限">
                      <Group gap={5}>
                        {key.models.map((model) => (
                          <Badge
                            className="model-id"
                            variant="light"
                            key={model}
                          >
                            {model}
                          </Badge>
                        ))}
                        {key.visionInput && (
                          <Badge variant="outline">视觉</Badge>
                        )}
                        {key.imageGeneration && (
                          <Badge variant="outline">图片生成 / 编辑</Badge>
                        )}
                      </Group>
                    </Table.Td>
                    <Table.Td data-label="状态">
                      <Badge
                        color={key.enabled ? "green" : "gray"}
                        variant="light"
                      >
                        {key.enabled ? "启用" : "禁用"}
                      </Badge>
                      <Text
                        size="xs"
                        c={
                          api.expirationState(key.expiresAtUnixSeconds) ===
                          "expired"
                            ? "red"
                            : api.expirationState(key.expiresAtUnixSeconds) ===
                                "soon"
                              ? "orange"
                              : "dimmed"
                        }
                      >
                        {api.expirationLabel(key.expiresAtUnixSeconds)}
                      </Text>
                      {key.expiresAtUnixSeconds != null && (
                        <Text
                          size="xs"
                          title={timeTitle(key.expiresAtUnixSeconds)}
                        >
                          {new Date(key.expiresAtUnixSeconds * 1000)
                            .toISOString()
                            .slice(0, 10)}{" "}
                          UTC 00:00
                        </Text>
                      )}
                    </Table.Td>
                    <Table.Td data-label="本地限制">
                      <Text size="sm">
                        {api.formatKeyLimit(key.limits.requests)} / 日
                      </Text>
                      <Text size="xs" c="dimmed">
                        {api.formatKeyLimit(key.limits.active)} 并发 ·{" "}
                        {api.formatKeyLimit(key.limits.unresolved)} 待核对
                      </Text>
                    </Table.Td>
                    <Table.Td data-label="今日 / 最近使用">
                      <Text size="sm">
                        {usage.data?.find((item) => item.keyID === key.id)
                          ?.admitted ?? "—"}{" "}
                        请求 / {api.formatKeyLimit(key.limits.requests)} 上限
                      </Text>
                      <Text size="xs">
                        费用：
                        {money(
                          usage.data?.find((item) => item.keyID === key.id)
                            ?.estimatedMicros,
                        )}
                      </Text>
                      <Text
                        size="xs"
                        title={timeTitle(
                          usage.data?.find((item) => item.keyID === key.id)
                            ?.lastUsedAtUnixSeconds,
                        )}
                      >
                        最近：
                        {usage.data?.find((item) => item.keyID === key.id)
                          ?.lastUsedAtUnixSeconds == null
                          ? "从未使用"
                          : localTime(
                              usage.data?.find((item) => item.keyID === key.id)
                                ?.lastUsedAtUnixSeconds,
                            )}
                      </Text>
                    </Table.Td>
                    <Table.Td data-label="操作">
                      <Group gap="xs">
                        <Button
                          size="compact-sm"
                          variant="subtle"
                          component={Link}
                          to={`/usage?key=${encodeURIComponent(key.id)}`}
                        >
                          用量
                        </Button>
                        <Button
                          size="compact-sm"
                          variant="subtle"
                          disabled={state.disabled}
                          onClick={() => state.setEditing(key)}
                        >
                          编辑
                        </Button>
                        <Menu position="bottom-end">
                          <Menu.Target>
                            <Button
                              size="compact-sm"
                              variant="subtle"
                              disabled={state.disabled}
                              aria-label={`${key.principal} 更多操作`}
                            >
                              更多
                            </Button>
                          </Menu.Target>
                          <Menu.Dropdown>
                            <Menu.Item onClick={() => setExpiring(key)}>
                              设置到期时间
                            </Menu.Item>
                            <Menu.Item onClick={() => state.setRotating(key)}>
                              轮换
                            </Menu.Item>
                            <Menu.Item
                              color={key.enabled ? "red" : undefined}
                              onClick={() =>
                                key.enabled
                                  ? setDisabling(key)
                                  : void toggle(key)
                              }
                            >
                              {key.enabled ? "禁用" : "启用"}
                            </Menu.Item>
                          </Menu.Dropdown>
                        </Menu>
                      </Group>
                    </Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </div>
          {!keys.length && (
            <Text ta="center" c="dimmed" py="xl">
              {state.keys.length ? "没有匹配的密钥。" : "尚未创建密钥。"}
            </Text>
          )}
        </Paper>
      )}
      <Modal
        lockScroll={false}
        opened={!!expiring}
        onClose={() => {
          if (!state.busy) setExpiring(null);
        }}
        title="设置 Key 到期时间"
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        {expiring && (
          <ExpirationEditor
            key={`${expiring.id}-${expiring.revision}`}
            entry={expiring}
            disabled={state.disabled}
            save={async (expires) => {
              const ok = await state.mutate(
                (csrf, signal) =>
                  api.setExpiration(expiring, expires, csrf, signal),
                expires === null ? "到期时间已清除。" : "到期时间已更新。",
              );
              setExpiring(null);
              return ok;
            }}
          />
        )}
      </Modal>
      <Modal
        lockScroll={false}
        opened={!!disabling}
        onClose={() => {
          if (!state.busy) setDisabling(null);
        }}
        title="禁用 API Key"
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        <Stack>
          <Text>
            禁用后，持有该 Key
            的客户端会立即失败，后续请求将被拒绝。请先通知使用者。
          </Text>
          <Text>{disabling?.principal}</Text>
          <Group justify="flex-end">
            <Button
              variant="default"
              disabled={state.busy}
              onClick={() => setDisabling(null)}
            >
              取消
            </Button>
            <Button
              color="red"
              disabled={state.disabled}
              onClick={async () => {
                if (disabling) {
                  await toggle(disabling);
                  setDisabling(null);
                }
              }}
            >
              确认禁用
            </Button>
          </Group>
        </Stack>
      </Modal>
      <Drawer
        lockScroll={false}
        opened={state.creating || !!state.editing}
        onClose={() => {
          if (!state.busy) {
            state.setCreating(false);
            state.setEditing(null);
          }
        }}
        closeButtonProps={{ "aria-label": "关闭" }}
        title={state.editing ? "编辑密钥权限" : "创建密钥"}
        position="right"
        size="lg"
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        {(state.creating || state.editing) && (
          <KeyEditor
            key={state.editing?.id ?? "new"}
            entry={state.editing ?? undefined}
            models={state.models}
            imageModels={state.imageModels}
            disabled={state.disabled}
            close={() => {
              state.setCreating(false);
              state.setEditing(null);
            }}
            submit={(draft) =>
              state.editing
                ? state.mutate(
                    (csrf, signal) =>
                      api.updateKey(
                        state.editing!,
                        state.editing!.enabled,
                        draft.models,
                        draft.limits,
                        csrf,
                        signal,
                        draft,
                      ),
                    "权限与限额已更新。",
                  )
                : state.mutate(
                    (csrf, signal) => api.createKey(draft, csrf, signal),
                    "密钥已创建，请保存一次性凭证。",
                  )
            }
          />
        )}
      </Drawer>
      <Modal
        lockScroll={false}
        opened={!!state.rotating}
        onClose={() => {
          if (!state.busy) state.setRotating(null);
        }}
        closeButtonProps={{ "aria-label": "关闭" }}
        title="轮换 API Key"
        closeOnEscape={!state.busy}
        closeOnClickOutside={!state.busy}
        withCloseButton={!state.busy}
      >
        <Stack>
          <Text>
            旧凭证将立即失效。主体、限额与历史计数保留，启用状态不变。
          </Text>
          <Text>新凭证只显示一次。</Text>
          <Group justify="flex-end">
            <Button
              variant="default"
              disabled={state.busy}
              onClick={() => state.setRotating(null)}
            >
              取消
            </Button>
            <Button
              disabled={state.disabled}
              onClick={() =>
                void state.mutate(
                  (csrf, signal) =>
                    api.rotateKey(state.rotating!, csrf, signal),
                  "凭证已轮换，旧凭证失效。",
                )
              }
            >
              确认轮换
            </Button>
          </Group>
        </Stack>
      </Modal>
      <Modal
        lockScroll={false}
        opened={!!state.created}
        onClose={() => state.setCreated(null)}
        closeButtonProps={{ "aria-label": "关闭" }}
        title="保存一次性凭证"
      >
        {state.created && (
          <Stack>
            <Text>
              {state.created.key.principal} ·{" "}
              {state.created.key.enabled ? "已启用" : "当前禁用"}
            </Text>
            <TextInput
              classNames={{ input: "secret-value" }}
              label="新 API Key"
              readOnly
              value={state.created.secret}
              autoComplete="off"
              onFocus={(event) => event.currentTarget.select()}
            />
            <Text size="sm">仅显示这一次，关闭、离开页面或五分钟后清除。</Text>
            <Group>
              <Button onClick={() => void state.copySecret()}>复制凭证</Button>
              <Button variant="default" onClick={() => state.setCreated(null)}>
                我已保存，关闭
              </Button>
            </Group>
            {state.copyState && <Text role="status">{state.copyState}</Text>}
          </Stack>
        )}
      </Modal>
    </section>
  );
}

function ExpirationEditor({
  entry,
  disabled,
  save,
}: {
  entry: api.ManagedKey;
  disabled: boolean;
  save: (expires: number | null) => Promise<boolean>;
}) {
  const [date, setDate] = useState(
    entry.expiresAtUnixSeconds == null
      ? ""
      : new Date(entry.expiresAtUnixSeconds * 1000).toISOString().slice(0, 10),
  );
  const epoch = date ? Date.parse(date + "T00:00:00Z") / 1000 : NaN;
  const valid =
    Number.isSafeInteger(epoch) && epoch > 0 && epoch <= 1_000_000_000_000;
  return (
    <Stack>
      <Text>{entry.principal}</Text>
      <TextInput
        label="到期日期（UTC）"
        type="date"
        value={date}
        disabled={disabled}
        onChange={(event) => setDate(event.currentTarget.value)}
        description="所选日期 UTC 00:00 起失效（快捷项至少保留整 N 天）；到期后拒绝新请求，已派发请求继续。"
      />
      <Group>
        {[30, 90].map((days) => (
          <Button
            key={days}
            variant="light"
            disabled={disabled}
            onClick={() =>
              setDate(
                new Date(Date.now() + (days + 1) * 86400000)
                  .toISOString()
                  .slice(0, 10),
              )
            }
          >
            +{days} 天
          </Button>
        ))}
      </Group>
      {valid && epoch <= Date.now() / 1000 && (
        <Alert color="yellow">该日期已过去，保存后会立即拒绝新请求。</Alert>
      )}
      <Group justify="flex-end">
        <Button
          variant="default"
          disabled={disabled || entry.expiresAtUnixSeconds == null}
          onClick={() => void save(null)}
        >
          清除到期时间
        </Button>
        <Button disabled={disabled || !valid} onClick={() => void save(epoch)}>
          保存到期时间
        </Button>
      </Group>
    </Stack>
  );
}
