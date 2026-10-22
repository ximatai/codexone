import { useEffect, useRef, useState, type FormEvent } from "react";
import * as sessionAPI from "../../shared/management";
import * as api from "./api";
import type { Account, AccountMode, AuthorizationFlow } from "./api";
const modes = { enabled: "允许使用", draining: "排空中", disabled: "已禁用" };
const authorization = { ready: "授权有效", refreshing: "正在刷新", requires_auth: "需要重新授权", auth_uncertain: "授权结果未知" };
function failure(error: unknown): string {
  if (error instanceof sessionAPI.ManagementError) {
    if (error.code === "authorization_required") return "上游授权已失效。请重新读取账号后重新授权。";
    if (error.status === 409) return "状态已变化或授权流程已结束。请重新读取账号，核对后再操作。";
    if (error.status === 400) return "授权信息无效，本次流程已结束。请重新发起授权。";
  }
  return "操作结果未确认。请重新读取账号核对，系统不会自动重复提交。";
}
export function AccountManagement() {
  const [session, setSession] = useState<sessionAPI.AdminSession | null>(null);
  const [checking, setChecking] = useState(true);
  const [logoutUnconfirmed, setLogoutUnconfirmed] = useState(false);
  const proof = useRef<string | null>(null);
  const [secret, setSecret] = useState("");
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [configured, setConfigured] = useState(true);
  const [busy, setBusy] = useState(false);
  const [locked, setLocked] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [flow, setFlow] = useState<(AuthorizationFlow & { accountID?: string }) | null>(null);
  const [callback, setCallback] = useState("");
  const [remaining, setRemaining] = useState(0);
  const controller = useRef<AbortController | null>(null);
  const epoch = useRef(0);
  const deadline = useRef(0);
  function current(version: number) { return version === epoch.current && !controller.current?.signal.aborted; }
  function clearFlow() { setFlow(null); setCallback(""); setRemaining(0); }
  async function read(version: number, signal?: AbortSignal, quietUnauthorized = false) {
    try {
      const fresh = await sessionAPI.fetchSession(signal);
      if (!current(version)) return false;
      const replaced = !!proof.current && proof.current !== fresh.csrf;
      if (replaced) {
        clearFlow(); setNotice("管理会话已更新，请重新发起需要的授权流程。");
      }
      proof.current = fresh.csrf; setSession(fresh);
      const list = await api.fetchAccounts(signal);
      if (!current(version)) return false;
      setAccounts(list); setConfigured(true); setLocked(false);
      return replaced ? "replaced" : "same";
    } catch (cause) {
      if (current(version)) {
        setLocked(true);
        if (cause instanceof sessionAPI.ManagementError && cause.status === 404) {
          setConfigured(false); setError("");
        } else if (cause instanceof sessionAPI.ManagementError && cause.status === 401) {
          proof.current = null; setSession(null); setAccounts([]); clearFlow(); setNotice(""); setError(quietUnauthorized ? "" : "管理会话已失效，请重新登录。");
        } else { setError("账号读取失败。重新读取成功前暂停变更。"); }
      }
      return false;
    }
  }
  useEffect(() => {
    const abort = new AbortController(); controller.current = abort;
    const version = ++epoch.current;
    void read(version, abort.signal, true).finally(() => { if (current(version)) setChecking(false); });
    return () => { ++epoch.current; abort.abort(); };
    // This effect owns the page's entire lifetime and request cancellation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (!flow) return;
    const timer = window.setInterval(() => {
      const seconds = Math.max(0, Math.ceil((deadline.current - performance.now()) / 1000));
      setRemaining(seconds);
      if (!seconds) { clearFlow(); setError("授权流程已过期，请重新发起。"); }
    }, 500);
    return () => window.clearInterval(timer);
  }, [flow]);
  async function login(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError("");
    const value = secret; setSecret(""); const version = epoch.current;
    try {
      const signedIn = await sessionAPI.login(value, controller.current?.signal);
      if (!current(version)) return;
      proof.current = signedIn.csrf; setSession(signedIn); await read(version, controller.current?.signal);
    } catch { if (current(version)) setError("登录失败，请检查管理员凭证和连接后重试。"); }
    finally { if (current(version)) setBusy(false); }
  }
  async function reread() {
    if (logoutUnconfirmed) return;
    setBusy(true); setError(""); setNotice(""); const version = epoch.current;
    await read(version, controller.current?.signal);
    if (current(version)) setBusy(false);
  }
  async function mutation(work: (csrf: string, signal?: AbortSignal) => Promise<unknown>, success: string) {
    if (!session || busy || locked || logoutUnconfirmed) return;
    setBusy(true); setError(""); setNotice(""); const version = epoch.current;
    try {
      await work(session.csrf, controller.current?.signal);
      if (!current(version)) return;
      setLocked(true);
      const refreshed = await read(version, controller.current?.signal);
      if (refreshed === "same" && current(version)) setNotice(success);
    } catch (cause) {
      if (current(version)) {
        setLocked(true); setError(failure(cause));
        if (cause instanceof sessionAPI.ManagementError && cause.status === 401) {
          proof.current = null; setSession(null); setAccounts([]); clearFlow(); setNotice(""); setError("管理会话已失效，请重新登录。");
        }
      }
    } finally { if (current(version)) setBusy(false); }
  }
  async function begin(account: Account | null) {
    await mutation(async (csrf, signal) => {
      const value = await api.beginAuthorization(account, csrf, signal);
      if (signal?.aborted) return;
      deadline.current = performance.now() + value.expiresInSeconds * 1000;
      setRemaining(value.expiresInSeconds); setFlow({ ...value, ...(account ? { accountID: account.id } : {}) });
    }, "授权流程已准备好，请在新窗口完成登录。");
  }
  async function complete(event: FormEvent) {
    event.preventDefault(); if (!flow || !callback.trim() || !remaining || busy || locked) return;
    const pending = flow, value = callback.trim(); clearFlow();
    await mutation((csrf, signal) => api.completeAuthorization(pending.flowID, value, csrf, signal), pending.accountID ? "重新授权已完成，账号身份与使用策略保持不变。" : "授权已验证并保存，新账号默认禁用。");
  }
  async function cancel() {
    if (!flow || !session) return;
    const id = flow.flowID; clearFlow();
    await mutation((csrf, signal) => api.discardAuthorization(id, csrf, signal), "本次授权已取消。");
  }
  async function logout() {
    if (busy || (!session && !logoutUnconfirmed)) return;
    clearFlow(); setSecret(""); setAccounts([]); setNotice(""); setSession(null); proof.current = null;
    setLocked(true); setLogoutUnconfirmed(true); setBusy(true); setError(""); const version = epoch.current;
    try {
      const fresh = await sessionAPI.fetchSession(controller.current?.signal);
      if (!current(version)) return;
      await sessionAPI.logout(fresh.csrf, controller.current?.signal);
      if (current(version)) setLogoutUnconfirmed(false);
    } catch (cause) {
      if (current(version)) {
        if (cause instanceof sessionAPI.ManagementError && cause.status === 401) setLogoutUnconfirmed(false);
        else setError("登出未确认，请再次登出。");
      }
    } finally { if (current(version)) setBusy(false); }
  }
  function setMode(account: Account, mode: AccountMode) {
    void mutation((csrf, signal) => api.setMode(account, mode, csrf, signal), "账号策略已更新。");
  }
  if (checking) return <p role="status">正在检查管理会话…</p>;
  return <section className="key-management account-management" aria-labelledby="accounts-heading">
    <div className="intro"><p className="eyebrow">SUBSCRIPTION ACCOUNTS</p><h1 id="accounts-heading">订阅账号</h1><p className="subtle">管理授权与使用策略。禁用保留历史归属，重新授权不会更换账号身份。</p></div>
    {error && <p role="alert" className="error-banner">{error}</p>}
    {notice && <p role="status" className="success-banner">{notice}</p>}
    {logoutUnconfirmed ? <div className="panel login-panel key-create"><h2>登出状态待确认</h2><p className="subtle field-hint">本页账号与授权信息已清除。确认退出前暂停管理操作。</p><button disabled={busy} onClick={() => void logout()}>重试登出</button></div> : !session ? <form className="panel login-panel key-create" onSubmit={(event) => void login(event)}>
      <h2>管理员登录</h2><p className="subtle field-hint">使用独立管理员凭证。凭证只用于本次登录，不保存在浏览器中。</p>
      <label className="text-field">管理员凭证<input type="password" autoComplete="off" value={secret} onChange={(event) => setSecret(event.target.value)} disabled={busy} required /></label>
      <button disabled={busy || !secret}>登录</button>
    </form> : <>
      <div className="key-toolbar"><span className="subtle">{accounts.length} 个账号 · 单管理员</span><div className="actions"><button onClick={() => void reread()} disabled={busy}>重新读取账号</button><button className="text-button" onClick={() => void logout()} disabled={busy}>登出</button></div></div>
      {!configured ? <div className="panel key-list"><h2>账号接入尚未开启</h2><p className="subtle">请由服务维护者完成账号安全配置，再重新读取。</p></div> : <div className="accounts-grid">
        <div className="panel key-create"><h2>{flow?.accountID ? "重新授权账号" : "接入订阅账号"}</h2><p className="subtle field-hint">每次授权只接入一个订阅身份。新账号先保持禁用，核对后可允许使用。</p>
          <button disabled={busy || locked || !!flow || accounts.length >= 64} onClick={() => void begin(null)}>发起账号授权</button>
          {flow && <form className="authorization-flow" onSubmit={(event) => void complete(event)}>
            <p><strong>1. 完成订阅登录</strong></p><a className="authorization-link" href={flow.authorizationURL} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">在新窗口打开授权页面 ↗</a>
            <p className="subtle field-hint">登录后会跳转到本机回调地址。即使显示无法连接，也可复制地址栏中的完整地址，粘贴到下方。本流程剩余 {remaining} 秒。</p>
            <label className="text-field">2. 粘贴完整回调地址<input type="password" autoComplete="off" spellCheck={false} maxLength={7000} value={callback} onChange={(event) => setCallback(event.target.value)} disabled={busy || locked} required /></label>
            <p className="subtle field-hint">地址含一次性授权码，请勿分享。提交后清除，离开页面也不会保存。</p>
            <div className="actions"><button disabled={busy || locked || !callback.trim() || !remaining}>验证并保存</button><button type="button" className="text-button" disabled={busy || locked} onClick={() => void cancel()}>取消本次授权</button></div>
          </form>}
          {!flow && <p className="subtle field-hint">需要重新授权时，请使用右侧对应账号的操作。</p>}
        </div>
        <div className="panel key-list"><h2>账号与授权状态</h2><p className="subtle field-hint">排空仅保留已有身份关联；授权结果未知时请重新授权，系统不会重复使用旧刷新令牌。</p>
          {!accounts.length ? <p className="empty-state subtle">还没有订阅账号。从左侧发起授权。</p> : <div className="table-scroll"><table><thead><tr><th>账号</th><th>使用策略</th><th>授权</th><th>操作</th></tr></thead><tbody>{accounts.map((account) => <tr key={account.id}>
            <td><div className="key-id" title={account.id}>{account.id}</div><small>凭证 v{account.credentialVersion} · 修订 {account.revision}</small></td>
            <td><span>{modes[account.mode]}</span><div className="row-actions account-modes">{(["enabled", "draining", "disabled"] as const).filter((mode) => mode !== account.mode).map((mode) => <button className="text-button" key={mode} disabled={busy || locked || !!flow} onClick={() => setMode(account, mode)}>{mode === "enabled" ? "启用" : mode === "draining" ? "排空" : "禁用"}</button>)}</div></td>
            <td><span className={account.authorization === "ready" ? "state-ready" : "state-attention"}>{authorization[account.authorization]}</span></td>
            <td><div className="account-row-actions"><button className="text-button" disabled={busy || locked || !!flow || account.authorization !== "ready"} onClick={() => void mutation((csrf, signal) => api.refreshAccount(account, csrf, signal), "授权刷新已完成。")}>刷新授权</button><button className="text-button" disabled={busy || locked || !!flow || account.authorization === "refreshing"} onClick={() => void begin(account)}>重新授权</button></div></td>
          </tr>)}</tbody></table></div>}
        </div>
      </div>}
    </>}
  </section>;
}
