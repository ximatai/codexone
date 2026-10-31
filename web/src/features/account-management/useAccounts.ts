import { useManagementSession } from "../../shared/session";
import { useEffect, useRef, useState, type FormEvent } from "react";
import * as sessionAPI from "../../shared/management";
import * as api from "./api";
import type { Account, AccountMode, AuthorizationFlow } from "./api";
function failure(error: unknown): string {
  if (error instanceof sessionAPI.ManagementError) {
    if (error.code === "authorization_required")
      return "上游授权已失效。请重新读取账号后重新授权。";
    if (error.status === 409)
      return "状态已变化或授权流程已结束。请重新读取账号，核对后再操作。";
    if (error.status === 400)
      return "提交内容无效，请检查显示名或授权信息后重试。";
  }
  return "操作结果未确认。请重新读取账号核对，系统不会自动重复提交。";
}
export function useAccounts() {
  const owner = useManagementSession();
  const [session, setSession] = useState<sessionAPI.AdminSession | null>(
    owner.session,
  );
  const [checking, setChecking] = useState(true);
  const proof = useRef<string | null>(owner.session?.csrf ?? null);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [configured, setConfigured] = useState(true);
  const [busy, setBusy] = useState(false);
  const [locked, setLocked] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNoticeValue] = useState("");
  const [noticeTone, setNoticeTone] = useState("success");
  const [clock, setClock] = useState(performance.now());
  function setNotice(text: string, tone = "success") {
    setNoticeValue(text);
    setNoticeTone(tone);
  }
  const [flow, setFlow] = useState<
    (AuthorizationFlow & { accountID?: string }) | null
  >(null);
  const [callback, setCallback] = useState("");
  const [remaining, setRemaining] = useState(0);
  const controller = useRef<AbortController | null>(null);
  const epoch = useRef(0);
  const deadline = useRef(0);
  function current(version: number) {
    return version === epoch.current && !controller.current?.signal.aborted;
  }
  function clearFlow() {
    setFlow(null);
    setCallback("");
    setRemaining(0);
  }
  async function read(
    version: number,
    signal?: AbortSignal,
    quietUnauthorized = false,
  ) {
    try {
      const fresh = await sessionAPI.fetchSession(signal);
      if (!current(version)) return false;
      const replaced = !!proof.current && proof.current !== fresh.csrf;
      if (replaced) {
        clearFlow();
        setNotice("管理会话已更新，请重新发起需要的授权流程。");
      }
      proof.current = fresh.csrf;
      setSession(fresh);
      if (!owner.adopt(fresh)) return false;
      const list = await api.fetchAccounts(signal);
      if (!current(version)) return false;
      setAccounts(list);
      setConfigured(true);
      setLocked(false);
      owner.lock("accounts", false);
      return replaced ? "replaced" : "same";
    } catch (cause) {
      if (current(version)) {
        setLocked(true);
        if (
          cause instanceof sessionAPI.ManagementError &&
          cause.status === 404
        ) {
          setConfigured(false);
          setError("");
        } else if (
          cause instanceof sessionAPI.ManagementError &&
          cause.status === 401
        ) {
          proof.current = null;
          owner.invalidate();
          setSession(null);
          setAccounts([]);
          clearFlow();
          setNotice("");
          setError(quietUnauthorized ? "" : "管理会话已失效，请重新登录。");
        } else {
          setError("账号读取失败。重新读取成功前暂停变更。");
        }
      }
      return false;
    }
  }
  useEffect(() => {
    const abort = new AbortController();
    controller.current = abort;
    const timer = window.setInterval(() => setClock(performance.now()), 15000);
    const version = ++epoch.current;
    void read(version, abort.signal, true).finally(() => {
      if (current(version)) setChecking(false);
    });
    return () => {
      // This numeric epoch deliberately retires the current owner on exit.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      ++epoch.current;
      abort.abort();
      window.clearInterval(timer);
    };
    // This effect owns the page's entire lifetime and request cancellation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (!flow) return;
    const timer = window.setInterval(() => {
      const seconds = Math.max(
        0,
        Math.ceil((deadline.current - performance.now()) / 1000),
      );
      setRemaining(seconds);
      if (!seconds) {
        clearFlow();
        setError("授权流程已过期，请重新发起。");
      }
    }, 500);
    return () => window.clearInterval(timer);
  }, [flow]);
  async function reread() {
    setBusy(true);
    setError("");
    setNotice("");
    const version = epoch.current;
    await read(version, controller.current?.signal);
    if (current(version)) setBusy(false);
  }
  async function mutation<T>(
    work: (csrf: string, signal?: AbortSignal) => Promise<T>,
    success: string | ((result: T) => { text: string; warning: boolean }),
  ) {
    if (!session || busy || locked || owner.locked("accounts")) return;
    owner.lock("accounts", true);
    setBusy(true);
    setError("");
    setNotice("");
    const version = epoch.current;
    try {
      const result = await work(session.csrf, controller.current?.signal);
      if (!current(version)) return;
      setLocked(true);
      const refreshed = await read(version, controller.current?.signal);
      if (refreshed === "same" && current(version)) {
        const notice =
          typeof success === "string"
            ? { text: success, warning: false }
            : success(result);
        setNotice(notice.text, notice.warning ? "warning" : "success");
      }
    } catch (cause) {
      if (current(version)) {
        setLocked(true);
        setError(failure(cause));
        if (
          cause instanceof sessionAPI.ManagementError &&
          cause.status === 409
        ) {
          const refreshed = await read(version, controller.current?.signal);
          if (current(version))
            setError(
              refreshed
                ? "记录已被其他操作修改，账号已刷新，请重新确认后操作。"
                : "记录已变化，刷新失败，请重新读取账号后再操作。",
            );
        }
        if (
          cause instanceof sessionAPI.ManagementError &&
          cause.status === 401
        ) {
          proof.current = null;
          owner.invalidate();
          setSession(null);
          setAccounts([]);
          clearFlow();
          setNotice("");
          setError("管理会话已失效，请重新登录。");
        }
      }
    } finally {
      if (current(version)) setBusy(false);
    }
  }
  async function begin(account: Account | null) {
    const version = epoch.current;
    await mutation(async (csrf, signal) => {
      const value = await api.beginAuthorization(account, csrf, signal);
      if (signal?.aborted || !current(version)) return;
      deadline.current = performance.now() + value.expiresInSeconds * 1000;
      setRemaining(value.expiresInSeconds);
      setFlow({ ...value, ...(account ? { accountID: account.id } : {}) });
    }, "授权流程已准备好，请在新窗口完成登录。");
  }
  async function complete(event: FormEvent) {
    event.preventDefault();
    if (!flow || !callback.trim() || !remaining || busy || locked) return;
    const pending = flow,
      value = callback.trim();
    clearFlow();
    await mutation(
      (csrf, signal) =>
        api.completeAuthorization(pending.flowID, value, csrf, signal),
      pending.accountID
        ? "重新授权已完成，账号身份与使用策略保持不变。"
        : "授权已验证并保存，新账号默认禁用。",
    );
  }
  async function cancel() {
    if (!flow || !session) return;
    const id = flow.flowID;
    clearFlow();
    await mutation(
      (csrf, signal) => api.discardAuthorization(id, csrf, signal),
      "本次授权已取消。",
    );
  }
  function setMode(account: Account, mode: AccountMode) {
    void mutation(
      (csrf, signal) => api.setMode(account, mode, csrf, signal),
      "账号策略已更新。",
    );
  }
  function invalidate() {
    ++epoch.current;
    proof.current = null;
    owner.invalidate();
    setSession(null);
    setAccounts([]);
    clearFlow();
    setNotice("");
    setLocked(true);
    setBusy(false);
  }
  return {
    accounts,
    configured,
    checking,
    busy,
    locked: locked || owner.locked("accounts"),
    error,
    notice,
    noticeTone,
    clock,
    flow,
    callback,
    setCallback,
    remaining,
    reread,
    mutation,
    begin,
    complete,
    cancel,
    setMode,
    invalidate,
  };
}
