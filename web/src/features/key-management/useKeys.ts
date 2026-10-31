import { notifications } from "@mantine/notifications";
import { useQueryClient } from "@tanstack/react-query";
import { queryKeys } from "../../shared/query-keys";
import { useManagedMutation } from "../../shared/useManagedMutation";
import { useEffect, useRef, useState } from "react";
import { useManagementSession } from "../../shared/session";
import * as api from "./api";
import type { KeyCreated, ManagedKey, KeyDraft } from "./api";
function message(error: unknown): string {
  if (!(error instanceof api.ManagementError))
    return "无法连接管理服务，请稍后重试。";
  if (error.status === 401) return "管理会话已结束，请重新登录。";
  if (error.status === 403)
    return error.code === "invalid_csrf"
      ? "管理会话已更新，请刷新后重试。"
      : "当前页面来源或会话验证不通过，请使用正确的管理地址。";
  return "管理服务暂时不可用，请稍后重试。";
}
export function useKeys() {
  const [creating, setCreating] = useState(false);
  const owner = useManagementSession();
  const [checking, setChecking] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [loading, setLoading] = useState(false);
  const client = useQueryClient();
  const uncertain = owner.locked("keys");
  const setUncertain = (value: boolean) => owner.lock("keys", value);
  const [keys, setKeys] = useState<ManagedKey[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [imageModels, setImageModels] = useState<string[]>([]);
  const [error, setError] = useState("");

  const [editing, setEditing] = useState<ManagedKey | null>(null);
  const [rotating, setRotating] = useState<ManagedKey | null>(null);
  const [created, setCreated] = useState<KeyCreated | null>(null);
  const partialCreation = useRef(false);
  const partialEdit = useRef(false);
  const [expirationFailure, setExpirationFailure] = useState(false);
  const [copyState, setCopyState] = useState("");
  useEffect(() => {
    if (creating || editing) notifications.hide("management-keys");
  }, [creating, editing]);
  const visibleSecret = useRef(created);
  visibleSecret.current = created;
  const lifetime = useRef<AbortController | null>(null);
  const readSequence = useRef(0);
  function clearPrivateState() {
    setKeys([]);
    setModels([]);
    setImageModels([]);
    setCreated(null);
    setEditing(null);
    setRotating(null);
    setCreating(false);
  }
  async function reload(signal: AbortSignal, quiet = false): Promise<boolean> {
    notifications.hide("management-keys");
    const sequence = ++readSequence.current;
    setLoading(true);
    setError("");
    try {
      const active = await api.fetchSession(signal);
      if (
        signal.aborted ||
        sequence !== readSequence.current ||
        !owner.adopt(active)
      )
        return false;
      const [entries, options] = await Promise.all([
        client.fetchQuery({
          queryKey: queryKeys.keys.list(),
          queryFn: () => api.fetchKeys(signal),
          staleTime: 0,
        }),
        api.fetchOptions(signal),
      ]);
      if (signal.aborted || sequence !== readSequence.current) return false;
      setKeys(entries);
      setModels(options.models);
      setImageModels(options.imageModels);
      setUnavailable(false);
      setUncertain(false);
      return true;
    } catch (failure) {
      if (signal.aborted || sequence !== readSequence.current) return false;
      if (failure instanceof api.ManagementError && failure.status === 401) {
        owner.invalidate();
        clearPrivateState();
      } else if (
        failure instanceof api.ManagementError &&
        failure.status === 404
      ) {
        setUnavailable(true);
        clearPrivateState();
      } else if (!quiet) setError(message(failure));
      return false;
    } finally {
      if (!signal.aborted && sequence === readSequence.current) {
        setLoading(false);
        setChecking(false);
      }
    }
  }
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    // reload belongs to the immutable session generation that mounted this page.
    void reload(controller.signal);
    return () => {
      controller.abort();
      readSequence.current += 1;
    };
    // The session generation remounts this owner; reload is intentionally mount-scoped.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (!created) return;
    const timer = window.setTimeout(() => setCreated(null), 300_000);
    return () => window.clearTimeout(timer);
  }, [created]);
  const mutation = useManagedMutation({
    scope: "keys",
    errorMessage: () =>
      partialCreation.current
        ? "密钥已创建但到期设置失败，请保存凭证并刷新列表核对到期时间；勿重复创建。"
        : partialEdit.current
          ? "权限与限额已保存，显示名未保存或结果待核对；请核对刷新后的列表再操作。"
          : undefined,
    invalidMessage: "提交内容不符合要求，请检查模型、限额与到期时间。",
    invalidate: [
      queryKeys.keys.all,
      queryKeys.usage.all,
      queryKeys.overview.all,
    ],
    refresh: (signal) => reload(signal, true),
    onFailure: () => {
      setCreating(false);
      setEditing(null);
      setRotating(null);
    },
  });
  const busy = mutation.busy;
  async function mutate(
    operation: (
      csrf: string,
      signal: AbortSignal,
    ) => Promise<ManagedKey | KeyCreated>,
    success: string,
    expires?: number | null,
  ): Promise<boolean> {
    if (loading) return false;
    return mutation.run(async (csrf, signal) => {
      partialCreation.current = false;
      partialEdit.current = false;
      const result = await operation(csrf, signal);
      if (signal.aborted) return;
      let key = "secret" in result ? result.key : result;
      if ("secret" in result) {
        setExpirationFailure(false);
        setCreated(result);
        setCopyState("");
        setCreating(false);
        if (expires != null) {
          try {
            key = await api.setExpiration(key, expires, csrf, signal);
          } catch (error) {
            if (!signal.aborted) {
              partialCreation.current = true;
              setExpirationFailure(true);
            }
            throw error;
          }
        }
      }
      setKeys((old) =>
        old.some((item) => item.id === key.id)
          ? old.map((item) => (item.id === key.id ? key : item))
          : [key, ...old],
      );
      setEditing(null);
      setRotating(null);
      setCreating(false);
    }, success);
  }
  async function saveEdit(
    key: ManagedKey,
    draft: KeyDraft,
    csrf: string,
    signal: AbortSignal,
  ) {
    const policyChanged =
      (draft.displayName ?? null) === (key.displayName ?? null) ||
      JSON.stringify([
        key.models,
        key.limits,
        key.visionInput ?? false,
        key.imageGeneration ?? false,
        key.imageModels ?? [],
      ]) !==
        JSON.stringify([
          draft.models,
          draft.limits,
          draft.visionInput ?? false,
          draft.imageGeneration ?? false,
          draft.imageModels ?? [],
        ]);
    let updated = key;
    if (policyChanged)
      updated = await api.updateKey(
        key,
        key.enabled,
        draft.models,
        draft.limits,
        csrf,
        signal,
        draft,
      );
    if ((draft.displayName ?? null) === (updated.displayName ?? null))
      return updated;
    try {
      return await api.setDisplayName(
        updated,
        draft.displayName ?? null,
        csrf,
        signal,
      );
    } catch (error) {
      if (policyChanged && !signal.aborted) {
        partialEdit.current = true;
        setEditing(null);
        if (!(await reload(signal, true)))
          throw new Error("Partial key edit requires reconciliation");
      }
      throw error;
    }
  }
  async function copySecret() {
    const target = created;
    const signal = lifetime.current?.signal;
    if (!target || !signal || signal.aborted) return;
    try {
      await navigator.clipboard.writeText(target.secret);
      if (!signal.aborted && visibleSecret.current === target)
        setCopyState("已复制");
    } catch {
      if (!signal.aborted && visibleSecret.current === target)
        setCopyState("复制失败，请手动选择复制。");
    }
  }
  const disabled = busy || loading || uncertain;
  return {
    keys,
    models,
    imageModels,
    checking,
    unavailable,
    loading,
    busy,
    uncertain,
    disabled,
    error,
    creating,
    setCreating,
    editing,
    setEditing,
    rotating,
    setRotating,
    created,
    setCreated,
    copyState,
    expirationFailure,
    mutate,
    saveEdit,
    copySecret,
    reload: () => {
      const signal = lifetime.current?.signal;
      if (signal) void reload(signal);
    },
  };
}
