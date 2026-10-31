import { notifications } from "@mantine/notifications";
import { useQueryClient } from "@tanstack/react-query";
import { queryKeys } from "../../shared/query-keys";
import { useManagedMutation } from "../../shared/useManagedMutation";
import { useEffect, useRef, useState } from "react";
import { useManagementSession } from "../../shared/session";
import * as api from "./api";
import type { KeyCreated, ManagedKey } from "./api";
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
  const [copyState, setCopyState] = useState("");
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
  ): Promise<boolean> {
    if (loading) return false;
    return mutation.run(async (csrf, signal) => {
      const result = await operation(csrf, signal);
      if (signal.aborted) return;
      const key = "secret" in result ? result.key : result;
      setKeys((old) =>
        old.some((item) => item.id === key.id)
          ? old.map((item) => (item.id === key.id ? key : item))
          : [key, ...old],
      );
      setEditing(null);
      setRotating(null);
      setCreating(false);
      if ("secret" in result) {
        setCreated(result);
        setCopyState("");
      }
    }, success);
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
    mutate,
    copySecret,
    reload: () => {
      const signal = lifetime.current?.signal;
      if (signal) void reload(signal);
    },
  };
}
