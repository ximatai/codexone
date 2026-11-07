import { z } from "../../shared/schema";
import { request } from "../../shared/management";

export const attentionQueryKey = ["overview", "attention"] as const;
const item = z.object({
  kind: z.enum([
    "account_requires_auth",
    "account_auth_uncertain",
    "account_cooldown",
    "quota_high",
    "reset_credits",
    "quota_priming",
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
export const report = z.object({
  generatedAtUnixSeconds: z.number(),
  items: z.array(item).max(50),
});
export type AttentionItem = z.infer<typeof item>;
export async function fetchAttention(signal: AbortSignal) {
  return report.parse(await request("/api/attention", { signal }));
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
