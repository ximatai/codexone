import { useCallback, useEffect, useRef, useState } from "react";
import {
  Alert,
  Button,
  Drawer,
  Group,
  Modal,
  Paper,
  Progress,
  Select,
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
import { PageHeader } from "../../shared/ui/PageHeader";
import { ConfirmModal } from "../../shared/ui/ConfirmModal";
import { KeyList } from "./KeyList";
import { ExpirationEditor } from "./ExpirationEditor";
import { ErrorState, StatusBadge, LoadingState } from "../../shared/ui/States";
import { queryKeys } from "../../shared/query-keys";
import {
  Link,
  useLocation,
  useNavigationType,
  useSearchParams,
} from "react-router";
import { readPage } from "../../shared/view-memory";
import { KeyName } from "../../shared/KeyName";
import { localTime } from "../../shared/presentation";
export function KeyManagement() {
  const navigationType = useNavigationType();
  const locationKey = useLocation().key;
  const positionedLocation = useRef<string | null>(null);
  const [params, setParams] = useSearchParams();
  const [selectedDetailID, setDetailID] = useState<string | null>(null);
  const linkedDetailID = params.get("detail");
  const detailID = selectedDetailID ?? linkedDetailID;
  const closeDetails = useCallback(() => {
    setDetailID(null);
    if (linkedDetailID) {
      setParams(
        (previous) => {
          const next = new URLSearchParams(previous);
          next.delete("detail");
          return next;
        },
        { replace: true },
      );
    }
  }, [linkedDetailID, setParams]);
  const status = params.get("status") ?? "available";
  const state = useKeys(
    status === "all" || status === "" ? "all" : status === "archived",
    closeDetails,
  );
  const owner = useManagementSession();
  const detail = state.keys.find((key) => key.id === detailID);
  const detailOpened =
    detailID !== null && (!linkedDetailID || detail !== undefined);
  useEffect(() => {
    if (detailID && state.readAt !== null && !state.loading && !detail)
      closeDetails();
  }, [detailID, detail, state.readAt, state.loading, closeDetails]);
  const [refresh, setRefresh] = useState(0);
  const search = params.get("q") ?? "";
  const target = params.get("target");
  const list = useRef<HTMLDivElement>(null);
  const paging = useRef<number | null>(null);
  const menuTrigger = useRef<HTMLElement | null>(null);
  const actionTrigger = useRef<HTMLElement | null>(null);
  function rememberMenuTrigger(key: api.ManagedKey) {
    const row = [
      ...(list.current?.querySelectorAll<HTMLElement>("[data-row-id]") ?? []),
    ].find((element) => element.dataset.rowId === key.id);
    menuTrigger.current = row?.querySelector<HTMLElement>("button") ?? null;
  }
  function returnToMenuTrigger() {
    if (state.created) return;
    if (
      actionTrigger.current?.isConnected &&
      !actionTrigger.current.hasAttribute("disabled")
    ) {
      actionTrigger.current.focus({ preventScroll: true });
      return;
    }
    if (document.querySelector('[data-ui-overlay="true"]')) {
      document
        .querySelector<HTMLElement>(
          `.${styles.detailContent} button[aria-label="关闭"]`,
        )
        ?.focus({ preventScroll: true });
      return;
    }
    if (menuTrigger.current?.isConnected)
      menuTrigger.current.focus({ preventScroll: true });
  }
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
  const [archiving, setArchiving] = useState<api.ManagedKey | null>(null);
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
    if (!state.readAt || state.loading || usage.isPending) return;
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
      // A pending filter render must not consume a later page button's scroll.
      if (paging.current !== null && paging.current !== page) return;
      if (positionedLocation.current === locationKey) return;
      positionedLocation.current = locationKey;
      if (paging.current === page) {
        paging.current = null;
        list.current?.scrollIntoView?.({ block: "start" });
        list.current?.focus({ preventScroll: true });
      } else if (targetIndex >= 0) {
        const row = [
          ...(list.current?.querySelectorAll<HTMLElement>("[data-row-id]") ??
            []),
        ].find((element) => element.dataset.rowId === target);
        row?.scrollIntoView?.({ block: "center" });
        row?.focus({ preventScroll: true });
      } else window.scrollTo?.(0, navigationType === "POP" ? (saved ?? 0) : 0);
    });
    const remember = () => owner.views.set(memoryKey, window.scrollY);
    window.addEventListener("scroll", remember);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", remember);
    };
  }, [
    identity,
    navigationType,
    locationKey,
    state.readAt,
    state.loading,
    usage.isPending,
    page,
    requestedPage,
    targetIndex,
    target,
    owner.views,
    setParams,
  ]);
  function changePage(nextPage: number) {
    paging.current = nextPage;
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
        <Select
          label="可用状态"
          disabled={state.busy}
          value={status}
          allowDeselect={false}
          onChange={(value) => filter("status", value ?? "")}
          data={[
            { value: "all", label: "全部" },
            { value: "available", label: "可用" },
            { value: "expiring", label: "即将到期" },
            { value: "expired", label: "已到期" },
            { value: "disabled", label: "已禁用" },
            { value: "archived", label: "已归档" },
          ]}
        />
        <Text size="sm" c="dimmed">
          {state.readAt === null ? "数量不可用" : `共 ${keys.length} 个`}
        </Text>
      </Paper>
      <Text
        size="xs"
        c="dimmed"
        mb="md"
        title="筛选按启用状态与有效期；权限和其他准入限制独立生效。"
      >
        业务日今日
        {usage.isError ? " · 今日摘要读取失败，请刷新重试。" : ""}
      </Text>
      {state.error && state.readAt !== null && (
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
            highlightedID={detailID ?? target}
            state={state}
            usage={usage}
            onDetails={(key) => {
              rememberMenuTrigger(key);
              setDetailID(key.id);
            }}
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
      <Drawer
        opened={detailOpened}
        onClose={() => {
          if (!state.busy) closeDetails();
        }}
        title={detail ? <KeyName {...detail} stacked /> : "密钥详情"}
        attributes={{ title: { "aria-label": "密钥详情" } }}
        classNames={{
          content: styles.detailContent,
          body: styles.detailBody,
          header: styles.detailHeader,
          title: styles.detailTitle,
          close: styles.detailClose,
        }}
        position="right"
        size="min(640px, 100vw)"
        closeButtonProps={{ "aria-label": "关闭" }}
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={detailOpened || undefined}
        closeOnEscape={
          !state.busy &&
          !expiring &&
          !archiving &&
          !disabling &&
          !state.rotating &&
          !state.created
        }
        closeOnClickOutside={!state.busy}
      >
        {!detail ? (
          <Alert>密钥已不在当前列表，请刷新核对。</Alert>
        ) : (
          <>
            <Stack className={styles.detailPanel} gap="md">
              <Stack className={styles.usageCard} gap="sm">
                <Group justify="space-between">
                  <StatusBadge
                    color={
                      detail.enabled &&
                      api.expirationState(detail.expiresAtUnixSeconds) !==
                        "expired"
                        ? "green"
                        : "gray"
                    }
                  >
                    {detail.archivedAtUnixSeconds != null
                      ? "已归档"
                      : api.expirationState(detail.expiresAtUnixSeconds) ===
                          "expired"
                        ? "已到期"
                        : detail.enabled
                          ? "启用"
                          : "禁用"}
                  </StatusBadge>
                  <Text size="xs" c="dimmed">
                    到期：
                    {detail.expiresAtUnixSeconds == null
                      ? "永不过期"
                      : localTime(detail.expiresAtUnixSeconds)}
                  </Text>
                </Group>
                <Group justify="space-between" align="center">
                  <div>
                    <Text size="xs" c="dimmed">
                      今日 Token / 上限
                    </Text>
                    <Text fw={700}>
                      {usage.isError
                        ? "不可用"
                        : (() => {
                            const value = usage.data?.find(
                              (item) => item.keyID === detail.id,
                            );
                            return value?.tokens == null
                              ? "不可用"
                              : `${value.tokenUsageIncomplete ? "≥ " : ""}${BigInt(value.tokens).toLocaleString("zh-CN")}`;
                          })()}{" "}
                      / {api.formatKeyLimit(detail.limits.tokens)}
                    </Text>
                  </div>
                  <Button
                    component={Link}
                    to={`/usage?key=${encodeURIComponent(detail.id)}`}
                    variant="subtle"
                    size="xs"
                  >
                    查看用量与诊断
                  </Button>
                </Group>
                {detail.limits.tokens != null &&
                  !usage.isError &&
                  (() => {
                    const observed = usage.data?.find(
                      (item) => item.keyID === detail.id,
                    );
                    return observed?.tokens == null ? null : (
                      <Progress
                        aria-label={
                          observed.tokenUsageIncomplete
                            ? "已观测 Token 比例下界"
                            : "今日 Token 使用比例"
                        }
                        value={Math.min(
                          100,
                          (Number(observed.tokens) / detail.limits.tokens!) *
                            100,
                        )}
                        size="sm"
                      />
                    );
                  })()}
              </Stack>
              <section aria-label="权限与限制">
                {detail.archivedAtUnixSeconds != null ? (
                  <Stack>
                    <Text>
                      对话模型：{detail.models?.join("、") ?? "全部模型"}
                    </Text>
                    <Text>
                      视觉输入：{detail.visionInput ? "允许" : "关闭"} ·
                      图片生成：{detail.imageGeneration ? "允许" : "关闭"}
                    </Text>
                    <Text>
                      并发：{api.formatKeyLimit(detail.limits.active)}
                    </Text>
                    <Text>
                      图片模型：
                      {detail.imageModels === null
                        ? "全部模型"
                        : detail.imageModels?.join("、") || "未配置"}
                    </Text>
                    <Text>
                      每日 Token：{api.formatKeyLimit(detail.limits.tokens)}
                    </Text>
                    <Text>归档密钥恢复后可编辑。</Text>
                  </Stack>
                ) : (
                  <KeyEditor
                    key={`${detail.id}-${detail.revision}`}
                    entry={detail}
                    hideCancel
                    hideSubmit
                    formId="key-detail-editor"
                    models={state.models}
                    imageModels={state.imageModels}
                    disabled={state.disabled}
                    close={closeDetails}
                    submit={(draft) =>
                      state.mutate(
                        (csrf, signal) =>
                          state.saveEdit(detail, draft, csrf, signal),
                        "密钥设置已更新。",
                      )
                    }
                  />
                )}
              </section>

              <div className={styles.keyMetadata} aria-label="密钥信息">
                <Text size="xs" c="dimmed">
                  创建于 {localTime(detail.createdAtUnixSeconds)}
                </Text>
              </div>
            </Stack>
            <section aria-label="管理操作" className={styles.manageActions}>
              <Group gap="xs" className={styles.footerButtons}>
                {detail.archivedAtUnixSeconds == null && (
                  <Button
                    type="submit"
                    form="key-detail-editor"
                    disabled={state.disabled}
                    className={styles.footerSave}
                  >
                    保存修改
                  </Button>
                )}
                {detail.archivedAtUnixSeconds == null && (
                  <>
                    <Button
                      variant="default"
                      disabled={state.disabled}
                      onClick={(event) => {
                        actionTrigger.current = event.currentTarget;
                        setExpiring(detail);
                      }}
                    >
                      设置到期时间
                    </Button>
                    <Button
                      variant="default"
                      disabled={state.disabled}
                      onClick={(event) => {
                        actionTrigger.current = event.currentTarget;
                        state.setRotating(detail);
                      }}
                    >
                      轮换凭证
                    </Button>
                    <Button
                      variant="light"
                      color={detail.enabled ? "red" : undefined}
                      disabled={state.disabled}
                      onClick={(event) => {
                        actionTrigger.current = event.currentTarget;
                        if (detail.enabled) setDisabling(detail);
                        else void toggle(detail);
                      }}
                    >
                      {detail.enabled ? "禁用" : "启用"}
                    </Button>
                  </>
                )}
                <Button
                  variant="default"
                  disabled={state.disabled || detail.enabled}
                  title={detail.enabled ? "请先禁用密钥，再归档" : undefined}
                  onClick={(event) => {
                    actionTrigger.current = event.currentTarget;
                    setArchiving(detail);
                  }}
                >
                  {detail.archivedAtUnixSeconds != null ? "恢复" : "归档"}
                </Button>
              </Group>
            </section>
          </>
        )}
      </Drawer>
      <Modal
        removeScrollProps={{ removeScrollBar: false }}
        data-ui-overlay={!!expiring || undefined}
        opened={!!expiring}
        returnFocus={false}
        onExitTransitionEnd={returnToMenuTrigger}
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
        returnFocusTo={returnToMenuTrigger}
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
      <ConfirmModal
        opened={!!archiving}
        returnFocusTo={returnToMenuTrigger}
        title={
          archiving?.archivedAtUnixSeconds != null ? "恢复密钥" : "归档密钥"
        }
        label={
          archiving?.archivedAtUnixSeconds != null ? "确认恢复" : "确认归档"
        }
        busy={state.busy}
        disabled={state.disabled}
        close={() => setArchiving(null)}
        destructive={false}
        confirm={async () => {
          if (archiving) {
            const archived = archiving.archivedAtUnixSeconds == null;
            await state.mutate(
              (csrf, signal) =>
                api.setArchived(archiving, archived, csrf, signal),
              archived ? "密钥已归档。" : "密钥已恢复，仍为停用状态。",
            );
            setArchiving(null);
          }
        }}
      >
        <Text>
          {archiving?.archivedAtUnixSeconds != null
            ? "恢复后仍为停用状态，需要单独启用。"
            : "归档后从默认列表隐藏，用量统计和审计保留，可在已归档视图恢复。"}
        </Text>
        <Text>{archiving?.displayName ?? archiving?.principal}</Text>
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
        returnFocusTo={returnToMenuTrigger}
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
            <Text component="div">
              {state.created.key.principal} ·{" "}
              <StatusBadge color="gray">
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
