import { useEffect, useRef, useState } from "react";
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

import { IconSearch, IconPlus, IconRefresh } from "@tabler/icons-react";
import styles from "./keys.module.css";
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
import { ErrorState, StatusBadge, LoadingState } from "../../shared/ui/States";
import { queryKeys } from "../../shared/query-keys";
import { useSearchParams } from "react-router";
import { readPage } from "../../shared/view-memory";
import { KeyName } from "../../shared/KeyName";
import { localTime } from "../../shared/presentation";
export function KeyManagement() {
  const state = useKeys();
  const owner = useManagementSession();
  const [refresh, setRefresh] = useState(0);
  const [params, setParams] = useSearchParams();
  const search = params.get("q") ?? "";
  const status = params.get("status") ?? "";
  const target = params.get("target");
  const list = useRef<HTMLDivElement>(null);
  const paging = useRef(false);
  const pageSize = 50;
  function filter(name: string, value: string) {
    setParams(
      (previous) => {
        const next = new URLSearchParams(previous);
        if (value) next.set(name, value);
        else next.delete(name);
        next.delete("page");
        return next;
      },
      { replace: true },
    );
  }
  const [expiring, setExpiring] = useState<api.ManagedKey | null>(null);
  const [disabling, setDisabling] = useState<api.ManagedKey | null>(null);
  const usage = useQuery({
    queryKey: [...queryKeys.usage.keys(), state.keys, refresh],
    queryFn: ({ signal }) => fetchKeyUsage(signal),
    enabled: !state.checking && !state.busy && !state.loading,
  });
  useEffect(() => {
    if (usage.error instanceof ManagementError && usage.error.status === 401)
      owner.invalidate();
  }, [usage.error, owner]);
  const keys = state.keys
    .filter(
      (key) =>
        ((key.displayName ?? "").toLowerCase().includes(search.toLowerCase()) ||
          key.principal.toLowerCase().includes(search.toLowerCase()) ||
          key.id.toLowerCase().includes(search.toLowerCase())) &&
        api.matchesAvailability(key, status),
    )
    .sort(
      (a, b) =>
        Number(b.enabled) - Number(a.enabled) ||
        a.principal.localeCompare(b.principal),
    );
  const pageCount = Math.max(1, Math.ceil(keys.length / pageSize));
  const requestedPage = readPage(params.get("page"), 6);
  const targetIndex = target ? keys.findIndex((key) => key.id === target) : -1;
  const page =
    targetIndex >= 0
      ? Math.floor(targetIndex / pageSize) + 1
      : Math.min(pageCount, requestedPage);
  const identity = params.toString();
  useEffect(() => {
    if (!state.readAt || state.loading) return;
    if (page !== requestedPage) {
      setParams(
        (previous) => {
          const next = new URLSearchParams(previous);
          next.set("page", String(page));
          return next;
        },
        { replace: true },
      );
      return;
    }
    const memoryKey = `keys:${identity}`;
    const saved = owner.views.get(memoryKey) as number | undefined;
    const frame = requestAnimationFrame(() => {
      if (paging.current) {
        paging.current = false;
        list.current?.scrollIntoView?.({ block: "start" });
        list.current?.focus({ preventScroll: true });
      } else if (targetIndex >= 0) {
        const row = [
          ...(list.current?.querySelectorAll<HTMLElement>("[data-row-id]") ??
            []),
        ].find((element) => element.dataset.rowId === target);
        row?.scrollIntoView?.({ block: "center" });
      } else if (saved !== undefined) window.scrollTo?.(0, saved);
    });
    const remember = () => owner.views.set(memoryKey, window.scrollY);
    window.addEventListener("scroll", remember);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", remember);
    };
  }, [
    identity,
    state.readAt,
    state.loading,
    page,
    requestedPage,
    targetIndex,
    target,
    owner.views,
    setParams,
  ]);
  function changePage(nextPage: number) {
    paging.current = true;
    setParams((previous) => {
      const next = new URLSearchParams(previous);
      next.set("page", String(nextPage));
      next.delete("target");
      return next;
    });
  }
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
        description="管理访问权限与本地用量限制。"
        actions={
          <Group>
            <Button
              variant="default"
              leftSection={<IconRefresh size={16} />}
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
              leftSection={<IconPlus size={16} />}
              onClick={() => state.setCreating(true)}
            >
              创建密钥
            </Button>
          </Group>
        }
      />
      <Paper withBorder p="md" mb="md" className={styles.toolbar}>
        <TextInput
          aria-label="搜索主体名"
          placeholder="搜索显示名、主体名或标识…"
          leftSection={<IconSearch size={18} />}
          value={search}
          onChange={(e) => filter("q", e.currentTarget.value)}
        />
        <NativeSelect
          label="可用状态"
          value={status}
          onChange={(event) => filter("status", event.currentTarget.value)}
          data={[
            { value: "", label: "全部" },
            { value: "available", label: "可用" },
            { value: "expiring", label: "即将到期" },
            { value: "expired", label: "已到期" },
            { value: "disabled", label: "已禁用" },
          ]}
        />
        <Text size="sm" c="dimmed">
          {state.readAt === null ? "数量不可用" : `共 ${keys.length} 个`}
        </Text>
      </Paper>
      <Text size="xs" c="dimmed" mb="sm">
        可用：启用且未到期；即将到期：可用且 7
        天内到期；已到期：不论开关；已禁用：未到期但关闭。仅按开关与有效期筛选，其他准入限制仍独立生效。
      </Text>
      <Text size="xs" c="dimmed" mb="md">
        今日统计按 UTC · {estimateNote}。
        {usage.isError ? "今日摘要读取失败，请刷新列表重试。" : ""}
      </Text>
      {state.error && (
        <ErrorState retry={state.reload}>
          {state.error}
          {state.readAt
            ? ` 上次成功读取：${localTime(state.readAt)}；快照可能已过时。`
            : ""}
        </ErrorState>
      )}
      {target && state.readAt && !state.error && targetIndex < 0 && (
        <Alert color="yellow" mb="sm">
          {state.keys.some((key) => key.id === target)
            ? "目标密钥被筛选隐藏。"
            : "目标密钥已不存在。"}
          <Button
            variant="subtle"
            onClick={() =>
              setParams(
                state.keys.some((key) => key.id === target) ? { target } : {},
                { replace: true },
              )
            }
          >
            重置筛选
          </Button>
        </Alert>
      )}
      {state.checking ? (
        <LoadingState>正在读取密钥…</LoadingState>
      ) : state.unavailable ? (
        <Alert>管理入口尚未启用</Alert>
      ) : (
        <Paper
          withBorder
          radius="md"
          p="md"
          ref={list}
          tabIndex={-1}
          className={styles.list}
        >
          <KeyList
            keys={keys.slice((page - 1) * pageSize, page * pageSize)}
            highlightedID={target}
            state={state}
            usage={usage}
            setExpiring={setExpiring}
            setDisabling={setDisabling}
            toggle={toggle}
          />
          {state.readAt !== null && (
            <Group mt="md" justify="flex-end">
              <Text size="sm">
                第 {page} / {pageCount} 页 · 每页 {pageSize} 个
              </Text>
              <Button
                variant="default"
                disabled={page <= 1}
                onClick={() => changePage(page - 1)}
              >
                上一页
              </Button>
              <Button
                variant="default"
                disabled={page >= pageCount}
                onClick={() => changePage(page + 1)}
              >
                下一页
              </Button>
            </Group>
          )}
        </Paper>
      )}
      <Modal
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!expiring || undefined}
        opened={!!expiring}
        onClose={() => {
          if (!state.busy) setExpiring(null);
        }}
        title="设置 Key 到期时间"
        closeButtonProps={{ "aria-label": "关闭" }}
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
        data-ui-overlay={state.creating || !!state.editing || undefined}
        opened={state.creating || !!state.editing}
        onClose={() => {
          if (!state.busy) {
            state.setCreating(false);
            state.setEditing(null);
          }
        }}
        closeButtonProps={{ "aria-label": "关闭" }}
        title={
          <Text component="span" size="xl" fw={700}>
            {state.editing ? "编辑密钥权限" : "创建密钥"}
          </Text>
        }
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
            submit={(draft, expires) =>
              state.editing
                ? state.mutate(
                    (csrf, signal) =>
                      state.saveEdit(state.editing!, draft, csrf, signal),
                    "密钥设置已更新。",
                  )
                : state.mutate(
                    (csrf, signal) => api.createKey(draft, csrf, signal),
                    "密钥已创建，请保存一次性凭证。",
                    expires,
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
        {state.rotating && (
          <Stack gap="xs">
            <Text className="wrap-anywhere">
              <KeyName {...state.rotating} />
            </Text>
            <TextInput
              label="密钥完整 ID"
              readOnly
              value={state.rotating.id}
              onFocus={(event) => event.currentTarget.select()}
            />
            <Text>当前开关：{state.rotating.enabled ? "启用" : "禁用"}</Text>
          </Stack>
        )}
        <Text>旧凭证将立即失效。主体、限额与历史计数保留，启用状态不变。</Text>
        <Text>新凭证只显示一次。</Text>
      </ConfirmModal>
      <Modal
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!state.created || undefined}
        opened={!!state.created}
        onClose={() => state.setCreated(null)}
        closeButtonProps={{ "aria-label": "关闭" }}
        title="保存一次性凭证"
      >
        {state.created && (
          <Stack>
            {state.expirationFailure && (
              <Alert color="red" role="alert">
                密钥已创建但到期设置失败，请保存凭证后刷新列表，核对并重新设置到期时间。
              </Alert>
            )}
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
