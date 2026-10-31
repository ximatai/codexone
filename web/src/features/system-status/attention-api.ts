import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
import { z } from "../../shared/schema";
import { request } from "../../shared/management";

export const attentionQueryKey = ["overview", "attention"] as const;
const item = z.object({
  kind: z.enum([
    "account_requires_auth",
    "account_auth_uncertain",
    "account_cooldown",
    "quota_high",
    "quota_stale",
    "key_expiring",
    "key_limit_near",
    "unresolved_executions",
    "observation_quality",
    "capacity_reference",
    "account_concurrency_high",
    "account_rate_surge",
    "error_rate_high",
    "storage_pressure",
    "backup_disabled",
    "backup_stale",
    "backup_size",
    "client_protocol_extension",
    "attention_source_unavailable",
  ]),
  severity: z.enum(["critical", "warning"]),
  subjectType: z.enum(["account", "key", "system", "protocol"]),
  subjectID: z.string().nullable(),
  subjectName: z.string().nullable(),
  detail: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])),
  sinceUnixSeconds: z.number().nullable(),
});
const report = z.object({
  generatedAtUnixSeconds: z.number(),
  items: z.array(item).max(50),
});
export type AttentionItem = z.infer<typeof item>;
export async function fetchAttention(signal: AbortSignal) {
  return report.parse(await request("/api/attention", { signal }));
}
export function attentionTarget(item: AttentionItem) {
  if (item.subjectType === "account")
    return `/accounts${item.subjectID ? `?target=${encodeURIComponent(item.subjectID)}` : ""}`;
  if (item.subjectType === "key")
    return `/keys${item.subjectID ? `?target=${encodeURIComponent(item.subjectID)}` : ""}`;
  if (item.kind.startsWith("backup_") || item.kind === "storage_pressure")
    return "/?storage=details";
  if (item.kind === "client_protocol_extension") return "/?protocol=details";
  if (item.kind === "attention_source_unavailable") {
    if (item.detail.source === "accounts") return "/accounts";
    if (item.detail.source === "keys") return "/keys";
    if (item.detail.source === "storage") return "/?storage=details";
  }
  return "/usage";
}
const messages: Record<AttentionItem["kind"], string> = {
  account_requires_auth: "账号需要重新授权",
  account_auth_uncertain: "账号授权结果待确认",
  account_cooldown: "账号正在执行健康冷却",
  quota_high: "订阅额度即将用尽",
  quota_stale: "订阅额度观测失败或已陈旧",
  key_expiring: "访问密钥已到期或将在 7 天内到期",
  key_limit_near: "访问密钥今日用量接近限额",
  unresolved_executions: "存在待核对的执行，请检查用量",
  observation_quality: "最近一小时非客户端取消的未知用量偏多，请检查观测质量",
  capacity_reference: "用量已接近参考阈值（仅提醒）",
  account_concurrency_high: "最近 24 小时峰值并发接近上限",
  account_rate_surge: "最近 10 分钟请求速率突增，请检查主要使用来源",
  error_rate_high: "最近一小时请求失败率偏高",
  storage_pressure: "存储压力已触发低盘保护",
  backup_disabled: "定时备份未启用，请配置独立备份目录",
  backup_stale: "已超过备份时限，请检查最近备份与磁盘空间",
  backup_size: "备份占用偏大，请检查容量并将备份另存异地",
  client_protocol_extension: "检测到新的客户端协议名称，请核对兼容性",
  attention_source_unavailable: "提醒数据源读取失败，请检查后重试",
};
export function attentionMessage(
  item: AttentionItem,
  accounts: readonly AccountName[] = [],
) {
  const name =
    item.subjectType === "account"
      ? accountName(item.subjectID, accounts, item.subjectName)
      : (item.subjectName ?? item.subjectID);
  const message =
    item.kind === "unresolved_executions"
      ? `未结执行占用 ${item.detail.unresolvedCount ?? item.detail.count} / ${item.detail.limit ?? "—"}，其中 ${item.detail.count} 条待核对`
      : messages[item.kind];
  const extra =
    item.kind === "capacity_reference"
      ? ` · ${item.detail.metric === "daily_requests" ? "今日请求" : item.detail.metric === "daily_estimated_micros" ? "今日估算费用（微美元）" : "明细行数"} ${item.detail.current} / ${item.detail.limit}${item.detail.exceeded ? "，已超过参考上限" : ""}`
      : item.kind === "quota_high" && item.detail.keyRanking
        ? ` · 最近 5 小时按 Key 消耗排名（已观测下界）：${item.detail.keyRanking}`
        : item.kind === "account_concurrency_high"
          ? ` · ${item.detail.peak} / ${item.detail.limit}`
          : item.kind === "account_rate_surge"
            ? ` · ${item.detail.count} 次，过去 7 天同时段中位数 ${item.detail.median}`
            : "";
  return `${name ? `${name}：` : ""}${message}${extra}`;
}

export async function releaseUnknown(
  beforeUnixSeconds: number,
  expectedCount: number,
  csrf: string,
  signal: AbortSignal,
) {
  return z.object({ released: z.number().int().nonnegative() }).parse(
    await request("/api/executions/unknown/release", {
      method: "POST",
      csrf,
      signal,
      body: { beforeUnixSeconds, expectedCount },
    }),
  );
}
