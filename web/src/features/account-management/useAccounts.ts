import { useManagedMutation } from "../../shared/useManagedMutation";
import { useManagementSession } from "../../shared/session";
import { useEffect, useRef, useState, type FormEvent } from "react";
import * as sessionAPI from "../../shared/management";
import * as api from "./api";
import type { Account, AccountMode, AuthorizationFlow } from "./api";
export function useAccounts() {
  const owner = useManagementSession();
  const [session, setSession] = useState<sessionAPI.AdminSession | null>(
    owner.session,
  );
  const [checking, setChecking] = useState(true);
  const proof = useRef<string | null>(owner.session?.csrf ?? null);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [readAt, setReadAt] = useState<number | null>(null);
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
  const flowRef = useRef<{ flowID: string; csrf: string } | null>(null);
  const targetRef = useRef<Account | null>(null);
  const flowEpoch = useRef(0);
  const [flowStatus, setFlowStatus] = useState<api.AuthorizationStatus | null>(
    null,
  );
  const [callback, setCallback] = useState("");
  const [remaining, setRemaining] = useState(0);
  const controller = useRef<AbortController | null>(null);
  const epoch = useRef(0);
  const deadline = useRef(0);
  function current(version: number) {
    return version === epoch.current && !controller.current?.signal.aborted;
  }
  function clearFlow() {
    ++flowEpoch.current;
    flowRef.current = null;
    setFlowStatus(null);
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
        const pending = flowRef.current;
        if (pending)
          void api
            .discardAuthorization(pending.flowID, pending.csrf)
            .catch(() => {});
        clearFlow();
        setNotice("管理会话已更新，请重新发起需要的授权流程。");
      }
      proof.current = fresh.csrf;
      setSession(fresh);
      if (!owner.adopt(fresh)) return false;
      const list = await api.fetchAccounts(signal);
      if (!current(version)) return false;
      setAccounts(list);
      setReadAt(Date.now() / 1000);
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
      const pending = flowRef.current;
      flowRef.current = null;
      if (pending)
        void api
          .discardAuthorization(pending.flowID, pending.csrf)
          .catch(() => {});
      abort.abort();
      window.clearInterval(timer);
    };
    // This effect owns the page's entire lifetime and request cancellation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (!flow || (flowStatus && flowStatus.status !== "pending")) return;
    const timer = window.setInterval(() => {
      const seconds = Math.max(
        0,
        Math.ceil((deadline.current - performance.now()) / 1000),
      );
      setRemaining(seconds);
      if (!seconds) {
        const pending = flowRef.current;
        if (pending)
          void api
            .discardAuthorization(pending.flowID, pending.csrf)
            .catch(() => {});
        flowRef.current = null;
        if (flow.method === "device") {
          setFlowStatus({ status: "expired", expiresInSeconds: 0 });
          setFlow({ ...flow, userCode: undefined });
        } else {
          clearFlow();
          setError("授权流程已过期，请重新发起。");
        }
      }
    }, 500);
    return () => window.clearInterval(timer);
  }, [flow, flowStatus]);
  useEffect(() => {
    if (
      flow?.method !== "device" ||
      flow.failureCode ||
      (flowStatus && flowStatus.status !== "pending")
    )
      return;
    const abort = new AbortController();
    const version = epoch.current;
    const generation = flowEpoch.current;
    let timer: number | undefined;
    async function poll() {
      try {
        const result = await api.fetchAuthorizationStatus(
          flow!.flowID,
          abort.signal,
        );
        if (
          abort.signal.aborted ||
          !current(version) ||
          generation !== flowEpoch.current
        )
          return;
        if (result.status === "pending") {
          // The server's deadline can shorten the local countdown, never extend it.
          deadline.current = Math.min(
            deadline.current,
            performance.now() + result.expiresInSeconds * 1000,
          );
          timer = window.setTimeout(() => void poll(), 1000);
          return;
        }
        setFlowStatus(result);
        setFlow((previous) =>
          previous ? { ...previous, userCode: undefined } : null,
        );
        if (result.status === "completed")
          await read(version, controller.current?.signal);
      } catch (cause) {
        if (
          abort.signal.aborted ||
          !current(version) ||
          generation !== flowEpoch.current
        )
          return;
        if (
          cause instanceof sessionAPI.ManagementError &&
          cause.status === 401
        ) {
          owner.invalidate();
          clearFlow();
          return;
        }
        setFlowStatus({
          status: "failed",
          expiresInSeconds: 0,
          failureCode: "status_unavailable",
        });
        setFlow((previous) =>
          previous ? { ...previous, userCode: undefined } : null,
        );
        const pending = flowRef.current;
        if (pending)
          void api
            .discardAuthorization(pending.flowID, pending.csrf)
            .catch(() => {});
      }
    }
    timer = window.setTimeout(() => void poll(), 1000);
    return () => {
      abort.abort();
      window.clearTimeout(timer);
    };
    // The flow id owns this read loop; terminal state retires it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flow?.flowID, flowStatus?.status]);
  async function reread() {
    setBusy(true);
    setError("");
    setNotice("");
    const version = epoch.current;
    await read(version, controller.current?.signal);
    if (current(version)) setBusy(false);
  }
  const managed = useManagedMutation({
    scope: "accounts",
    successNotification: false,
    errorMessage: (cause) =>
      cause instanceof sessionAPI.ManagementError &&
      cause.code === "authorization_required"
        ? "上游授权已失效。请重新读取账号后重新授权。"
        : undefined,
    invalidMessage: "提交内容无效，请检查显示名或授权信息后重试。",
    invalidate: [],
    refresh: async (signal) => !!(await read(epoch.current, signal)),
  });
  async function mutation<T>(
    work: (csrf: string, signal?: AbortSignal) => Promise<T>,
    success: string | ((result: T) => { text: string; warning: boolean }),
  ) {
    if (!session || busy || locked || managed.busy) return;
    setError("");
    setNotice("");
    await managed.run(
      async (csrf, signal) => {
        const result = await work(csrf, signal);
        if (signal.aborted) return;
        const refreshed = await read(epoch.current, signal);
        if (!refreshed) throw new Error("Account refresh failed");
        if (typeof success === "string") setNotice(success);
        else {
          const notice = success(result);
          setNotice(notice.text, notice.warning ? "warning" : "success");
        }
      },
      typeof success === "string" ? success : "额度观测已完成。",
    );
  }
  async function begin(
    account: Account | null,
    method: "device" | "callback" = "device",
  ) {
    targetRef.current = account;
    const generation = ++flowEpoch.current;
    const version = epoch.current;
    await mutation(async (csrf, signal) => {
      const value = await api.beginAuthorization(account, csrf, signal, method);
      if (
        signal?.aborted ||
        !current(version) ||
        generation !== flowEpoch.current
      ) {
        void api.discardAuthorization(value.flowID, csrf).catch(() => {});
        return;
      }
      flowRef.current = { flowID: value.flowID, csrf };
      setFlowStatus(
        value.failureCode
          ? {
              status: "failed",
              failureCode: value.failureCode,
              expiresInSeconds: 0,
            }
          : null,
      );
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
      async (csrf, signal) => {
        try {
          return await api.completeAuthorization(
            pending.flowID,
            value,
            csrf,
            signal,
          );
        } finally {
          void api.discardAuthorization(pending.flowID, csrf).catch(() => {});
        }
      },
      pending.accountID
        ? "重新授权已完成，账号身份与使用策略保持不变。"
        : "授权已验证并保存，新账号默认禁用。",
    );
  }
  async function cancel() {
    const pending = flowRef.current;
    clearFlow();
    if (pending) {
      try {
        await api.discardAuthorization(pending.flowID, pending.csrf);
      } catch {
        if (proof.current === pending.csrf)
          setError("取消结果尚未确认，流程会在期限结束后失效。");
      }
    }
  }
  async function switchToCallback() {
    const target = targetRef.current;
    await cancel();
    await begin(target, "callback");
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
    readAt,
    configured,
    checking,
    busy: busy || managed.busy,
    locked: locked || owner.locked("accounts"),
    error,
    notice,
    noticeTone,
    clock,
    flow,
    flowStatus,
    switchToCallback,
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
