import { ManagementError, request } from "../../shared/management";
export interface QuotaWindow { usedPercent: number | null; durationSeconds: number | null; resetsAtUnixSeconds: number | null }
export interface QuotaLimit { id: string; allowed: boolean | null; limitReached: boolean | null; primary: QuotaWindow | null; secondary: QuotaWindow | null }
export interface AccountObservability {
  observing: boolean; receivedAt: number;
  quota: { state: "fresh" | "stale" | "unavailable"; observedAtUnixSeconds: number | null; attemptedAtUnixSeconds: number | null; ageSeconds: number | null; freshForSeconds: number; failure: string | null; additionalCount: number; limits: QuotaLimit[] };
  health: { authenticationRejected: boolean; lastFailure: string | null; lastFailureAtUnixSeconds: number | null; cooldownCount: number; nextCooldownEndsAtUnixSeconds: number | null; cooldowns?: { model: string; untilUnixSeconds: number; failure: string }[] };
}
const invalid = () => new ManagementError(0, "invalid_response");
function object(value: unknown): Record<string, unknown> { if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid(); return value as Record<string, unknown>; }
function integer(value: unknown, maximum = 1_000_000_000_000): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > maximum) throw invalid(); return value; }
function time(value: unknown): number | null { if (value === null) return null; const number = integer(value); if (!number) throw invalid(); return number; }
function bool(value: unknown): boolean | null { if (value === null || typeof value === "boolean") return value; throw invalid(); }
function label(value: unknown): string { if (typeof value !== "string" || !value.length || value.length > 128) throw invalid(); return value; }
function failure(value: unknown): string | null { if (value === null) return null; if (typeof value !== "string" || !/^[a-z_]{1,64}$/.test(value)) throw invalid(); return value; }
function window(raw: unknown): QuotaWindow | null {
  if (raw === null) return null;
  const value = object(raw); const used = value.usedPercent;
  if (used !== null && (typeof used !== "number" || !Number.isFinite(used) || used < 0 || used > 10_000)) throw invalid();
  const duration = value.durationSeconds === null ? null : integer(value.durationSeconds, 31_536_000);
  if (duration === 0) throw invalid();
  return { usedPercent: used as number | null, durationSeconds: duration, resetsAtUnixSeconds: time(value.resetsAtUnixSeconds) };
}
export function parseObservability(raw: unknown): AccountObservability {
  const value = object(raw), quota = object(value.quota), health = object(value.health);
  if (typeof value.observing !== "boolean" || typeof health.authenticationRejected !== "boolean" || !["fresh", "stale", "unavailable"].includes(String(quota.state)) || !Array.isArray(quota.limits) || quota.limits.length > 17) throw invalid();
  const limits = quota.limits.map(raw => { const limit = object(raw); return { id: label(limit.id), allowed: bool(limit.allowed), limitReached: bool(limit.limitReached), primary: window(limit.primary), secondary: window(limit.secondary) }; });
  if (new Set(limits.map(limit => limit.id)).size !== limits.length) throw invalid();
  let cooldowns: AccountObservability["health"]["cooldowns"];
  if (health.cooldowns !== undefined) {
    if (!Array.isArray(health.cooldowns) || health.cooldowns.length > 48) throw invalid();
    cooldowns = health.cooldowns.map(raw => { const item = object(raw); const until = time(item.untilUnixSeconds); const code = failure(item.failure); if (!until || !code) throw invalid(); return { model: label(item.model), untilUnixSeconds: until, failure: code }; });
  }
  const age = quota.ageSeconds === null ? null : integer(quota.ageSeconds);
  const observedAt = time(quota.observedAtUnixSeconds), attemptedAt = time(quota.attemptedAtUnixSeconds);
  const remaining = integer(quota.freshForSeconds, 300), code = failure(quota.failure);
  if ((observedAt === null && age !== null) || (code && attemptedAt === null) || (quota.state === "fresh" && (observedAt === null || age === null || age >= 300 || remaining === 0))) throw invalid();
  if (cooldowns && cooldowns.length !== health.cooldownCount) throw invalid();
  return { observing: value.observing, receivedAt: performance.now(), quota: {
    state: quota.state as AccountObservability["quota"]["state"], observedAtUnixSeconds: observedAt, attemptedAtUnixSeconds: attemptedAt, ageSeconds: age, freshForSeconds: remaining, failure: code, additionalCount: integer(quota.additionalCount, 16), limits,
  }, health: { authenticationRejected: health.authenticationRejected, lastFailure: failure(health.lastFailure), lastFailureAtUnixSeconds: time(health.lastFailureAtUnixSeconds), cooldownCount: integer(health.cooldownCount, 48), nextCooldownEndsAtUnixSeconds: time(health.nextCooldownEndsAtUnixSeconds), ...(cooldowns ? { cooldowns } : {}) } };
}
export async function fetchObservation(id: string, signal?: AbortSignal): Promise<AccountObservability> { const started = performance.now(); const parsed = parseObservability(await request("/api/accounts/" + encodeURIComponent(id) + "/observation", { signal })); parsed.receivedAt = started; return parsed; }
export async function observeAccount(id: string, csrf: string, signal?: AbortSignal): Promise<AccountObservability> { const started = performance.now(); const parsed = parseObservability(await request("/api/accounts/" + encodeURIComponent(id) + "/observe", { method: "POST", body: {}, csrf, signal, timeout: 35000 })); parsed.receivedAt = started; return parsed; }
export function observationNotice(value: AccountObservability): string {
  if (value.quota.failure === "refresh_required") return "访问凭证已过期，请先刷新授权；最近成功的额度观测已保留。";
  if (value.quota.failure) return "本次额度读取失败，最近成功值已保留。请查看观测时间与失败状态。";
  return value.quota.state === "unavailable" ? "上游未提供可用额度窗口。" : "额度观测已更新。";
}
