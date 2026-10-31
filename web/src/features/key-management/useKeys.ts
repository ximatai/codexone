import { useEffect, useRef, useState } from "react";
import { useManagementSession } from "../../shared/session";
import * as api from "./api";
import type { KeyCreated, ManagedKey } from "./api";
function message(error: unknown, mutation = false): string {
  if (!(error instanceof api.ManagementError))
    return "无法连接管理服务，请稍后重试。";
  if (error.status === 401) return "管理会话已结束，请重新登录。";
  if (error.status === 403)
    return error.code === "invalid_csrf"
      ? "管理会话已更新，请刷新后重试。"
      : "当前页面来源或会话验证不通过，请使用正确的管理地址。";
  if (error.status === 409)
    return "记录已被其他操作修改，列表已刷新，请重新确认后操作。";
  if (error.status === 400 || error.status === 413)
    return "提交内容不符合要求，请检查模型、限额与到期时间。";
  if (mutation) return "操作结果尚未确认，请先刷新列表核对，再继续操作。";
  return "管理服务暂时不可用，请稍后重试。";
}
export function useKeys() {
  const [creating, setCreating] = useState(false);
  const owner = useManagementSession();
  const session = owner.session;
  const [checking, setChecking] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const uncertain = owner.locked("keys");
  const setUncertain = (value: boolean) => owner.lock("keys", value);
  const [keys, setKeys] = useState<ManagedKey[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [imageModels, setImageModels] = useState<string[]>([]);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
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
    setNotice("");
    setCreating(false);
  }
  async function reload(signal: AbortSignal): Promise<boolean> {
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
        api.fetchKeys(signal),
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
      } else setError(message(failure));
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
  async function mutate(
    operation: (
      csrf: string,
      signal: AbortSignal,
    ) => Promise<ManagedKey | KeyCreated>,
    success: string,
  ): Promise<boolean> {
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted || !session || uncertain || busy || loading)
      return false;
    setUncertain(true);
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const result = await operation(session.csrf, signal);
      if (signal.aborted) return false;
      const key = "secret" in result ? result.key : result;
      setKeys((old) =>
        old.some((item) => item.id === key.id)
          ? old.map((item) => (item.id === key.id ? key : item))
          : [key, ...old],
      );
      setEditing(null);
      setRotating(null);
      setCreating(false);
      setUncertain(false);
      if ("secret" in result) {
        setCreated(result);
        setCopyState("");
      }
      setNotice(success);
      return true;
    } catch (failure) {
      if (signal.aborted) return false;
      if (failure instanceof api.ManagementError && failure.status === 401) {
        owner.invalidate();
        clearPrivateState();
      } else if (
        failure instanceof api.ManagementError &&
        failure.status === 409
      ) {
        setEditing(null);
        setRotating(null);
        const refreshed = await reload(signal);
        if (!signal.aborted) {
          if (!refreshed) setUncertain(true);
          setError(
            refreshed
              ? message(failure)
              : "记录已被其他操作修改，刷新未完成。请重新连接并核对列表后再操作。",
          );
        }
        return false;
      } else if (
        !(failure instanceof api.ManagementError) ||
        failure.status === 0 ||
        failure.status === 403 ||
        failure.status >= 500
      ) {
        setUncertain(true);
        setCreating(false);
        setEditing(null);
        setRotating(null);
      }
      if (
        failure instanceof api.ManagementError &&
        failure.status >= 400 &&
        failure.status < 500 &&
        failure.status !== 403
      )
        setUncertain(false);
      if (!signal.aborted) setError(message(failure, true));
      return false;
    } finally {
      if (!signal.aborted) setBusy(false);
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
    notice,
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
