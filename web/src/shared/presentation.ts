/** Display units only. API values and governance continue to use integer micro USD. */
export const estimateNote = "按配置费率估算，非账单";
export function money(
  value: string | number | null | undefined,
  unlimited = false,
): string {
  if (value == null) return unlimited ? "不限" : "不可用";
  const cents = (BigInt(value) + 5000n) / 10000n;
  return `估算 $${(cents / 100n).toLocaleString("en-US")}.${(cents % 100n).toString().padStart(2, "0")}`;
}
export function dollarsToMicros(value: string | number): number {
  const raw = String(value);
  if (!/^\d+(\.\d{1,6})?$/.test(raw)) throw new Error("美元金额最多六位小数");
  const [whole, fraction = ""] = raw.split(".");
  const micros = BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, "0"));
  if (micros < 1n || micros > 1000000000000n) throw new Error("金额超出范围");
  return Number(micros);
}
export function microsToDollars(value: number): number {
  return value / 1000000;
}
export function moneyThreshold(value: number | null): string {
  if (value === null) return "不限";
  return `$${(value / 1000000).toFixed(6).replace(/\.?0+$/, "")}`;
}
export function localTime(value: number | null | undefined): string {
  return value == null
    ? "未提供"
    : new Date(value * 1000).toLocaleString("zh-CN", { hour12: false });
}
export function timeTitle(value: number | null | undefined): string {
  return value == null
    ? "未提供"
    : `${localTime(value)} / ${new Date(value * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC")}`;
}
export function resetIn(value: number | null, now = Date.now()): string {
  if (value === null) return "重置时间未提供";
  const minutes = Math.ceil((value * 1000 - now) / 60000);
  if (minutes <= 0) return "已到重置时间，等待读取";
  const days = Math.floor(minutes / 1440),
    hours = Math.floor((minutes % 1440) / 60),
    rest = minutes % 60;
  return (
    [
      days ? `${days} 天` : "",
      hours ? `${hours} 小时` : "",
      rest ? `${rest} 分` : "",
    ]
      .filter(Boolean)
      .join(" ") + "后重置"
  );
}
export const terms = {
  pending: "待核对",
  exposure: "待核对占用（预估）",
  requests: "请求",
};
export const failures: Record<string, string> = {
  authentication_rejected: "上游认证拒绝",
  rate_limited: "上游限流",
  upstream_unavailable: "上游暂不可用",
  upstream_rejected: "上游拒绝请求",
  invalid_upstream_response: "上游响应无效",
  deadline_exceeded: "执行期限到达",
  client_cancelled: "客户端断开/取消",
  key_rejected: "Key 不可用",
  model_not_allowed: "模型未授权",
  object_unavailable: "对象未知或不属于当前主体",
  object_ambiguous: "对象归属不唯一",
  local_capacity: "本地限额或容量",
  account_unavailable: "账号暂不可用",
  storage_unavailable: "账本存储不可用",
  invalid_request: "请求无效",
  indeterminate: "执行结果未明",
};
export const modes: Record<string, string> = {
  priming: "配额窗口预热",
  generation: "生成",
  warmup: "预热",
  compact: "压缩",
};
export const states: Record<string, string> = {
  intent: "在途",
  unknown: terms.pending,
  settled: "已核对",
  closed_unknown: "已关闭·用量未知",
};
export const outcomes: Record<string, string> = {
  succeeded: "成功返回",
  failed: "失败",
  cancelled: "取消",
};
export const metricLabels = {
  inputTokens: "输入 token",
  outputTokens: "输出 token",
  cachedTokens: "缓存 token",
  images: "图片",
  imageInputTokens: "图片输入 token",
  imageOutputTokens: "图片输出 token",
  imageInputTextTokens: "图片输入中的文本 token",
  imageInputImageTokens: "图片输入中的图像 token",
  estimatedMicros: "估算费用",
};
export const accountModes = {
  enabled: "允许使用",
  draining: "排空中",
  disabled: "已禁用",
};
export const authorizations = {
  ready: "授权有效",
  refreshing: "正在刷新",
  requires_auth: "需要重新授权",
  auth_uncertain: "授权结果未知",
};
export const limitLabels = {
  requests: "每日请求（UTC）",
  active: "同时执行",
  unresolved: "待核对请求数量",
  budgetMicros: "每日估算阈值（美元）",
  unresolvedMicros: "待核对占用阈值（美元）",
};
