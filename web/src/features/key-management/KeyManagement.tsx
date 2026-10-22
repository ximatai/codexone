import { useEffect } from "react";
import {
  Alert,
  Badge,
  Button,
  Drawer,
  Group,
  Menu,
  Modal,
  Paper,
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
export function KeyManagement() {
  const state = useKeys();
  const overlay =
    state.creating || !!state.editing || !!state.rotating || !!state.created;
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
            onClick={state.reload}
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
          <Table.ScrollContainer minWidth={750}>
            <Table verticalSpacing="md" highlightOnHover>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>主体 / 标识</Table.Th>
                  <Table.Th>权限</Table.Th>
                  <Table.Th>状态</Table.Th>
                  <Table.Th>本地限制</Table.Th>
                  <Table.Th>操作</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {state.keys.map((key) => (
                  <Table.Tr key={key.id}>
                    <Table.Td>
                      <Text fw={600}>{key.principal}</Text>
                      <Text
                        size="xs"
                        c="dimmed"
                        className="identifier"
                        title={key.id}
                      >
                        {key.id}
                      </Text>
                    </Table.Td>
                    <Table.Td>
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
                    <Table.Td>
                      <Badge
                        color={key.enabled ? "green" : "gray"}
                        variant="light"
                      >
                        {key.enabled ? "启用" : "禁用"}
                      </Badge>
                    </Table.Td>
                    <Table.Td>
                      <Text size="sm">
                        {key.limits.requests.toLocaleString()} / 日
                      </Text>
                      <Text size="xs" c="dimmed">
                        {key.limits.active} 并发 · {key.limits.unresolved} 未结
                      </Text>
                    </Table.Td>
                    <Table.Td>
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
                            <Menu.Item onClick={() => state.setRotating(key)}>
                              轮换
                            </Menu.Item>
                            <Menu.Item
                              color={key.enabled ? "red" : undefined}
                              onClick={() =>
                                void state.mutate(
                                  (csrf, signal) =>
                                    api.updateKey(
                                      key,
                                      !key.enabled,
                                      key.models,
                                      key.limits,
                                      csrf,
                                      signal,
                                    ),
                                  key.enabled ? "密钥已禁用。" : "密钥已启用。",
                                )
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
          </Table.ScrollContainer>
          {!state.keys.length && (
            <Text ta="center" c="dimmed" py="xl">
              尚未创建密钥。
            </Text>
          )}
        </Paper>
      )}
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
