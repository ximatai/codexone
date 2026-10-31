import { useEffect, useState } from "react";
import {
  Alert,
  Button,
  Drawer,
  Group,
  Modal,
  Paper,
  NativeSelect,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";

import * as api from "./api";
import { KeyEditor } from "./KeyEditor";
import { useKeys } from "./useKeys";
import { useQuery } from "@tanstack/react-query";
import { useManagementSession } from "../../shared/session";
import { ManagementError } from "../../shared/management";
import { fetchKeyUsage } from "../usage/api";
import { estimateNote } from "../../shared/presentation";
import { PageHeader } from "../../shared/ui/PageHeader";
import { ConfirmModal } from "../../shared/ui/ConfirmModal";
import { KeyList } from "./KeyList";
import { ExpirationEditor } from "./ExpirationEditor";
import { ErrorState, StatusBadge } from "../../shared/ui/States";
import { queryKeys } from "../../shared/query-keys";
export function KeyManagement() {
  const state = useKeys();
  const owner = useManagementSession();
  const [refresh, setRefresh] = useState(0);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("");
  const [expiring, setExpiring] = useState<api.ManagedKey | null>(null);
  const [disabling, setDisabling] = useState<api.ManagedKey | null>(null);
  const usage = useQuery({
    queryKey: [...queryKeys.usage.keys(), state.keys, refresh],
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
  return (
    <section>
      <PageHeader
        title="访问密钥"
        actions={
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
        }
      />
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
        <ErrorState retry={state.reload}>{state.error}</ErrorState>
      )}
      {state.checking ? (
        <p role="status">正在读取密钥…</p>
      ) : state.unavailable ? (
        <Alert>管理入口尚未启用</Alert>
      ) : (
        <Paper withBorder radius="md" p="md">
          <KeyList
            keys={keys}
            state={state}
            usage={usage}
            setExpiring={setExpiring}
            setDisabling={setDisabling}
            toggle={toggle}
          />
        </Paper>
      )}
      <Modal
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay="true"
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
      <ConfirmModal
        opened={!!disabling}
        title="禁用 API Key"
        label="确认禁用"
        busy={state.busy}
        disabled={state.disabled}
        close={() => setDisabling(null)}
        confirm={async () => {
          if (disabling) {
            await toggle(disabling);
            setDisabling(null);
          }
        }}
        destructive={true}
      >
        <Text>
          禁用后，持有该 Key
          的客户端会立即失败，后续请求将被拒绝。请先通知使用者。
        </Text>
        <Text>{disabling?.principal}</Text>
      </ConfirmModal>
      <Drawer
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay="true"
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
      <ConfirmModal
        opened={!!state.rotating}
        title="轮换 API Key"
        label="确认轮换"
        busy={state.busy}
        disabled={state.disabled}
        close={() => state.setRotating(null)}
        confirm={() =>
          void state.mutate(
            (csrf, signal) => api.rotateKey(state.rotating!, csrf, signal),
            "凭证已轮换，旧凭证失效。",
          )
        }
        destructive={false}
      >
        <Text>旧凭证将立即失效。主体、限额与历史计数保留，启用状态不变。</Text>
        <Text>新凭证只显示一次。</Text>
      </ConfirmModal>
      <Modal
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay="true"
        opened={!!state.created}
        onClose={() => state.setCreated(null)}
        closeButtonProps={{ "aria-label": "关闭" }}
        title="保存一次性凭证"
      >
        {state.created && (
          <Stack>
            <Text>
              {state.created.key.principal} ·{" "}
              <StatusBadge color={state.created.key.enabled ? "green" : "gray"}>
                {state.created.key.enabled ? "已启用" : "当前禁用"}
              </StatusBadge>
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
