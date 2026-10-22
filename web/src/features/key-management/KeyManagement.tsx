import { UsageOverview } from "../usage/UsageOverview";
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import * as api from "./api";
import type { AdminSession, KeyCreated, KeyDraft, KeyLimits, ManagedKey } from "./api";

type LimitDraft = Record<keyof KeyLimits, string>;
const defaults: KeyLimits = { requests: 1000, active: 4, unresolved: 8, budgetMicros: 1_000_000, unresolvedMicros: 1_000_000 };
const limitFields = [
  ["requests", "每日请求（UTC）"], ["active", "同时执行"], ["unresolved", "未结执行数量"],
  ["budgetMicros", "每日估算阈值（微单位）"], ["unresolvedMicros", "未结暴露阈值（微单位）"],
] as const;
function limitDraft(limits: KeyLimits): LimitDraft {
  return Object.fromEntries(limitFields.map(([field]) => [field, String(limits[field])])) as LimitDraft;
}
function parsedLimits(limits: LimitDraft): KeyLimits | null {
  const entries = limitFields.map(([field]) => [field, Number(limits[field])] as const);
  if (entries.some(([, value]) => !Number.isSafeInteger(value) || value < 1 || value > 1_000_000_000_000)) return null;
  return Object.fromEntries(entries) as unknown as KeyLimits;
}
function message(error: unknown, mutation = false): string {
  if (!(error instanceof api.ManagementError)) return "无法连接管理服务，请稍后重试。";
  if (error.status === 401) return "管理会话已结束，请重新登录。";
  if (error.status === 403) return error.code === "invalid_csrf" ? "管理会话已更新，请刷新后重试。" : "当前页面来源或会话验证不通过，请使用正确的管理地址。";
  if (error.status === 409) return "记录已被其他操作修改，列表已刷新，请重新确认后操作。";
  if (error.status === 400 || error.status === 413) return "提交内容不符合要求，请检查模型与限额。";
  if (mutation) return "操作结果尚未确认，请先刷新列表核对，再继续操作。";
  return "管理服务暂时不可用，请稍后重试。";
}
function Modal({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => { if (element?.open) element.close(); };
  }, []);
  return <dialog ref={dialog} aria-label={title} onCancel={(event) => { event.preventDefault(); onClose(); }}>
    <h2>{title}</h2>{children}
  </dialog>;
}
function PolicyFields({ available, selected, retained = [], limits, disabled, onSelected, onLimit }: {
  available: string[]; selected: string[]; retained?: string[]; limits: LimitDraft; disabled: boolean;
  onSelected: (models: string[]) => void; onLimit: (field: keyof KeyLimits, value: string) => void;
}) {
  const models = [...new Set([...available, ...retained])];
  return <>
    <fieldset disabled={disabled} className="model-fieldset"><legend>对话模型</legend>
      {models.length === 0 ? <p className="field-hint">尚无可用模型，请联系部署管理员。</p> : <div className="model-choices">
        {models.map((model) => <label key={model} className="model-choice"><input type="checkbox" checked={selected.includes(model)}
          disabled={!available.includes(model) && !selected.includes(model)}
          onChange={(event) => onSelected(event.target.checked ? [...selected, model] : selected.filter((item) => item !== model))} />
          <span>{model}{!available.includes(model) && <small>未配置，可取消授权</small>}</span></label>)}
      </div>}
    </fieldset>
    <div className="limit-fields">{limitFields.map(([field, label]) => <label key={field}>
      <span>{label}</span><input type="number" min="1" max="1000000000000" step="1" required value={limits[field]}
        disabled={disabled} onChange={(event) => onLimit(field, event.target.value)} />
    </label>)}</div>
    <p className="field-hint">本地治理阈值不代表订阅余额。预热、压缩也计入请求；未知用量不会按零结算。</p>
  </>;
}
function CreateForm({ models, disabled, submit }: { models: string[]; disabled: boolean; submit: (draft: KeyDraft) => Promise<boolean> }) {
  const [principal, setPrincipal] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [limits, setLimits] = useState(() => limitDraft(defaults));
  const [error, setError] = useState("");
  async function create(event: FormEvent) {
    event.preventDefault();
    const parsed = parsedLimits(limits);
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(principal) || selected.length === 0 || !parsed) { setError("请填写有效主体、选择模型，并填写正整数限额。"); return; }
    setError("");
    if (await submit({ principal, models: selected, limits: parsed })) { setPrincipal(""); setSelected([]); setLimits(limitDraft(defaults)); }
  }
  return <form className="panel key-create" onSubmit={(event) => { void create(event); }}>
    <h2>创建密钥</h2><p className="field-hint">主体用于隔离会话；创建后不可修改。</p>
    <label className="text-field">主体标识<input required maxLength={64} value={principal} placeholder="例如 team-a"
      disabled={disabled} onChange={(event) => setPrincipal(event.target.value)} /></label>
    <PolicyFields available={models} selected={selected} limits={limits} disabled={disabled}
      onSelected={setSelected} onLimit={(field, value) => setLimits((old) => ({ ...old, [field]: value }))} />
    {error && <p role="alert" className="error-text">{error}</p>}
    <button disabled={disabled || models.length === 0}>创建 API Key</button>
  </form>;
}
function EditForm({ entry, models, disabled, close, save }: {
  entry: ManagedKey; models: string[]; disabled: boolean; close: () => void;
  save: (models: string[], limits: KeyLimits) => Promise<boolean>;
}) {
  const [selected, setSelected] = useState(entry.models);
  const [limits, setLimits] = useState(() => limitDraft(entry.limits));
  const [error, setError] = useState("");
  async function submit(event: FormEvent) {
    event.preventDefault();
    const parsed = parsedLimits(limits);
    if (selected.length === 0 || !parsed) { setError("请选择至少一个模型，并填写正整数限额。"); return; }
    setError(""); await save(selected, parsed);
  }
  return <form onSubmit={(event) => { void submit(event); }}>
    <p>主体 <strong>{entry.principal}</strong><br /><small className="subtle key-id">{entry.id}</small></p>
    <PolicyFields available={models} selected={selected} retained={entry.models} limits={limits} disabled={disabled}
      onSelected={setSelected} onLimit={(field, value) => setLimits((old) => ({ ...old, [field]: value }))} />
    <p className="field-hint">创建于 {new Date(entry.createdAtUnixSeconds * 1000).toLocaleString("zh-CN", { timeZone: "UTC" })} UTC。修改只影响新的执行。</p>
    {error && <p role="alert" className="error-text">{error}</p>}
    <div className="actions"><button disabled={disabled}>保存修改</button><button type="button" className="secondary" disabled={disabled} onClick={close}>取消</button></div>
  </form>;
}

export function KeyManagement() {
  const [showUsage, setShowUsage] = useState(false);
  const [usageSelection, setUsageSelection] = useState<{ keyID: string; sequence: number } | null>(null);
  const [session, setSession] = useState<AdminSession | null>(null);
  const [checking, setChecking] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [uncertain, setUncertain] = useState(false);
  const [logoutUnconfirmed, setLogoutUnconfirmed] = useState(false);
  const [credential, setCredential] = useState("");
  const [keys, setKeys] = useState<ManagedKey[]>([]);
  const [models, setModels] = useState<string[]>([]);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [editing, setEditing] = useState<ManagedKey | null>(null);
  const [rotating, setRotating] = useState<ManagedKey | null>(null);
  const [created, setCreated] = useState<KeyCreated | null>(null);
  const [copyState, setCopyState] = useState("");
  const visibleSecret = useRef(created); visibleSecret.current = created;
  const lifetime = useRef<AbortController | null>(null);
  const readSequence = useRef(0);
  function clearPrivateState() {
    setShowUsage(false); setUsageSelection(null); setKeys([]); setModels([]); setCreated(null); setEditing(null); setRotating(null); setCredential(""); setNotice("");
  }
  async function reload(signal: AbortSignal): Promise<boolean> {
    const sequence = ++readSequence.current;
    setLoading(true); setError("");
    try {
      const active = await api.fetchSession(signal);
      const [entries, options] = await Promise.all([api.fetchKeys(signal), api.fetchOptions(signal)]);
      if (signal.aborted || sequence !== readSequence.current) return false;
      setSession(active); setKeys(entries); setModels(options); setUnavailable(false); setUncertain(false);
      return true;
    } catch (failure) {
      if (signal.aborted || sequence !== readSequence.current) return false;
      if (failure instanceof api.ManagementError && failure.status === 401) { setSession(null); clearPrivateState(); }
      else if (failure instanceof api.ManagementError && failure.status === 404) { setUnavailable(true); setSession(null); clearPrivateState(); }
      else setError(message(failure));
      return false;
    } finally {
      if (!signal.aborted && sequence === readSequence.current) { setLoading(false); setChecking(false); }
    }
  }
  useEffect(() => {
    const controller = new AbortController(); lifetime.current = controller;
    void reload(controller.signal);
    return () => { controller.abort(); readSequence.current += 1; };
  }, []);
  useEffect(() => {
    if (!created) return;
    const timer = window.setTimeout(() => setCreated(null), 300_000);
    return () => window.clearTimeout(timer);
  }, [created]);
  async function signIn(event: FormEvent) {
    event.preventDefault();
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted) return;
    setBusy(true); setError("");
    const supplied = credential; setCredential("");
    try { await api.login(supplied, signal); if (!signal.aborted) await reload(signal); }
    catch (failure) { if (!signal.aborted) setError(failure instanceof api.ManagementError && failure.status === 401 ? "管理员凭证无效，请重新输入。" : message(failure)); }
    finally { if (!signal.aborted) setBusy(false); }
  }
  async function signOut() {
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted || !session) return;
    setBusy(true); setLogoutUnconfirmed(true); setError(""); clearPrivateState(); readSequence.current += 1;
    try { const fresh = await api.fetchSession(signal); await api.logout(fresh.csrf, signal); if (!signal.aborted) { setSession(null); setLogoutUnconfirmed(false); } }
    catch (failure) {
      if (signal.aborted) return;
      if (failure instanceof api.ManagementError && failure.status === 401) { setSession(null); setLogoutUnconfirmed(false); }
      else { setLogoutUnconfirmed(true); setError("服务端登出尚未确认。本页内容已清除，请重试登出。"); }
    } finally { if (!signal.aborted) { setBusy(false); setLoading(false); } }
  }
  async function mutate(operation: (csrf: string, signal: AbortSignal) => Promise<ManagedKey | KeyCreated>, success: string): Promise<boolean> {
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted || !session || uncertain) return false;
    setBusy(true); setError(""); setNotice("");
    try {
      const result = await operation(session.csrf, signal);
      if (signal.aborted) return false;
      const key = "secret" in result ? result.key : result;
      setKeys((old) => old.some((item) => item.id === key.id) ? old.map((item) => item.id === key.id ? key : item) : [key, ...old]);
      setEditing(null); setRotating(null);
      if ("secret" in result) { setCreated(result); setCopyState(""); }
      setNotice(success); return true;
    } catch (failure) {
      if (signal.aborted) return false;
      if (failure instanceof api.ManagementError && failure.status === 401) { setSession(null); clearPrivateState(); }
      else if (failure instanceof api.ManagementError && failure.status === 409) {
        setEditing(null); setRotating(null);
        const refreshed = await reload(signal);
        if (!signal.aborted) {
          if (!refreshed) setUncertain(true);
          setError(refreshed ? message(failure) : "记录已被其他操作修改，刷新未完成。请重新连接并核对列表后再操作。");
        }
        return false;
      }
      else if (!(failure instanceof api.ManagementError) || failure.status === 0 || failure.status >= 500) { setUncertain(true); setEditing(null); setRotating(null); }
      if (!signal.aborted) setError(message(failure, true));
      return false;
    } finally { if (!signal.aborted) setBusy(false); }
  }
  async function copySecret() {
    const target = created;
    const signal = lifetime.current?.signal;
    if (!target || !signal || signal.aborted) return;
    try { await navigator.clipboard.writeText(target.secret); if (!signal.aborted && visibleSecret.current === target) setCopyState("已复制"); }
    catch { if (!signal.aborted && visibleSecret.current === target) setCopyState("复制失败，请手动选择复制。"); }
  }
  const disabled = busy || loading || uncertain;
  return <section className="key-management">
    <div className="intro"><span className="eyebrow">访问控制</span><h1>访问密钥</h1><p>按主体发放对话模型权限，独立设置本地治理限额。</p></div>
    {checking ? <div className="panel" role="status">正在验证管理会话…</div> : unavailable ? <div className="panel"><h2>管理入口尚未启用</h2><p>请联系部署管理员后刷新。</p><button onClick={() => { const signal = lifetime.current?.signal; if (signal) void reload(signal); }}>重新连接</button></div> : !session ? <form className="panel login-panel" onSubmit={(event) => { void signIn(event); }}>
      <h2>管理登录</h2><p>使用部署时配置的管理员凭证。普通 API Key 无法登录。</p>
      <label className="text-field">管理员凭证<input type="password" autoComplete="off" required value={credential} disabled={busy}
        onChange={(event) => setCredential(event.target.value)} /></label>
      <p className="field-hint">原文仅用于本次登录；管理会话最长 30 分钟。</p>
      {error && <p role="alert" className="error-text">{error}</p>}
      <button disabled={busy || loading}>{busy ? "正在登录…" : "登录管理台"}</button>
      {error && <button type="button" className="secondary" disabled={busy || loading} onClick={() => { const signal = lifetime.current?.signal; if (signal) void reload(signal); }}>重新连接</button>}
    </form> : <>
      <div className="key-toolbar"><span className="badge">管理员会话</span><div className="actions">
        {!logoutUnconfirmed && <button className="secondary" disabled={disabled} onClick={() => { setShowUsage(!showUsage); setUsageSelection(null); }}>{showUsage ? "收起用量与诊断" : "用量与请求诊断"}</button>}
        {!logoutUnconfirmed && <button className="secondary" disabled={busy || loading} onClick={() => { const signal = lifetime.current?.signal; if (signal) void reload(signal); }}>{loading ? "正在刷新…" : "刷新列表"}</button>}
        <button className="secondary" disabled={busy} onClick={() => { void signOut(); }}>{logoutUnconfirmed ? "重试登出" : "退出登录"}</button>
      </div></div>
      {error && <p role="alert" className="error-banner">{error}</p>}{notice && <p role="status" className="success-banner">{notice}</p>}
      {!logoutUnconfirmed && <div className="keys-grid">
        <CreateForm models={models} disabled={disabled} submit={(draft) => mutate((csrf, signal) => api.createKey(draft, csrf, signal), "密钥已创建，请保存一次性凭证。")} />
        <div className="panel key-list"><div className="panel-heading"><h2>已发放密钥</h2><span className="subtle">{keys.length} 个</span></div>
          <p className="field-hint">轮换保留主体、标识与限额。禁用停止新请求，已开始的执行仍会结算。</p>
          {keys.length === 0 ? <p className="empty-state">尚未创建密钥。先选择主体和模型权限，再发放凭证。</p> : <div className="table-scroll"><table><thead><tr><th>主体 / 标识</th><th>对话模型</th><th>状态</th><th>本地限制</th><th>操作</th></tr></thead><tbody>
            {keys.map((key) => <tr key={key.id}><td><strong>{key.principal}</strong><small className="key-id" title={key.id}>{key.id}</small></td>
              <td><div className="model-tags">{key.models.map((model) => <span className="model-tag" key={model}>{model}</span>)}</div></td>
              <td><span className={key.enabled ? "good" : "subtle"}>{key.enabled ? "启用" : "禁用"}</span></td>
              <td><span>{key.limits.requests.toLocaleString()} / 日</span><small>{key.limits.active} 并发 · {key.limits.unresolved} 未结</small></td>
              <td><div className="row-actions"><button className="text-button" disabled={disabled} onClick={() => { setUsageSelection(previous => ({ keyID: key.id, sequence: (previous?.sequence ?? 0) + 1 })); setShowUsage(true); }}>用量</button><button className="text-button" disabled={disabled} onClick={() => setEditing(key)}>编辑</button>
                <button className="text-button" disabled={disabled} onClick={() => setRotating(key)}>轮换</button>
                <button className="text-button" disabled={disabled} onClick={() => { void mutate((csrf, signal) => api.updateKey(key, !key.enabled, key.models, key.limits, csrf, signal), key.enabled ? "密钥已禁用。" : "密钥已启用。"); }}>{key.enabled ? "禁用" : "启用"}</button></div></td>
            </tr>)}
          </tbody></table></div>}
        </div>
      </div>}
      {!logoutUnconfirmed && showUsage && <UsageOverview selection={usageSelection} paused={disabled} onUnauthorized={() => { ++readSequence.current; setSession(null); clearPrivateState(); setError("管理会话已结束，请重新登录。"); }} />}
    </>}
    {editing && <Modal title="编辑密钥权限" onClose={() => { if (!busy) setEditing(null); }}><EditForm entry={editing} models={models} disabled={disabled}
      close={() => setEditing(null)} save={(selected, limits) => mutate((csrf, signal) => api.updateKey(editing, editing.enabled, selected, limits, csrf, signal), "权限与限额已更新。")} /></Modal>}
    {rotating && <Modal title="轮换 API Key" onClose={() => { if (!busy) setRotating(null); }}><p><strong>{rotating.principal}</strong> 的旧凭证将立即失效。标识、主体和已有计数保持，{rotating.enabled ? "Key 仍保持启用。" : "Key 仍保持禁用。"}</p>
      <p>新凭证只显示一次，请保存后更新客户端。</p><div className="actions"><button disabled={disabled} onClick={() => { void mutate((csrf, signal) => api.rotateKey(rotating, csrf, signal), "凭证已轮换，旧凭证失效。"); }}>确认轮换</button><button className="secondary" disabled={busy} onClick={() => setRotating(null)}>取消</button></div></Modal>}
    {created && <Modal title="保存一次性凭证" onClose={() => setCreated(null)}><p>主体 <strong>{created.key.principal}</strong> · {created.key.enabled ? "已启用" : "当前禁用，启用后才可访问"}</p>
      <label className="text-field">新 API Key<input className="secret-value" readOnly value={created.secret} autoComplete="off" onFocus={(event) => event.currentTarget.select()} /></label>
      <p>只显示这一次，关闭后无法找回。未保存时需要再次轮换。</p>
      <p className="field-hint">此窗口五分钟后自动清除。</p>
      <div className="actions"><button onClick={() => { void copySecret(); }}>复制凭证</button><button className="secondary" onClick={() => setCreated(null)}>我已保存，关闭</button></div>
      {copyState && <p role="status">{copyState}</p>}
    </Modal>}
  </section>;
}
