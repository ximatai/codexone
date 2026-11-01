import { z } from "../../shared/schema";
import { request } from "../../shared/management";
const identifier = z
  .string()
  .min(1)
  .max(256)
  .regex(/^[\x21-\x7e]+$/);
const timestamp = z
  .string()
  .max(64)
  .refine((v) => Number.isFinite(Date.parse(v)));
const optionalText = (max: number) =>
  z
    .string()
    .max(max)
    .nullish()
    .transform((v) => v ?? null);
const creditSchema = z.object({
  id: identifier,
  type: identifier.max(64),
  status: identifier.max(64),
  grantedAt: timestamp,
  expiresAt: timestamp.nullish().transform((v) => v ?? null),
  title: optionalText(512),
  description: optionalText(2048),
});
const code = z.enum([
  "reset",
  "nothing_to_reset",
  "no_credit",
  "already_redeemed",
  "unknown",
]);
const stateSchema = z.object({
  revision: z.number().int().min(1).max(1_000_000),
  settings: z.object({
    autoUseBeforeExpiry: z.boolean(),
    leadMinutes: z.number().int().min(1).max(10080),
    retryCount: z.number().int().min(0).max(5),
  }),
  pending: z.boolean(),
  pendingCreditID: identifier.nullable(),
  lastCode: code.nullable(),
  lastAttemptAt: z.number().int().positive().nullable(),
});
const listSchema = z.object({
  credits: z.array(creditSchema).max(128),
  availableCount: z.number().int().min(0).max(128),
  state: stateSchema,
});
export type ResetCredit = z.infer<typeof creditSchema>;
export type ResetCreditState = z.infer<typeof stateSchema>;
export type ResetCreditList = z.infer<typeof listSchema>;
export type ResetCreditCode = z.infer<typeof code>;
const base = (id: string) =>
  `/api/accounts/${encodeURIComponent(id)}/reset-credits`;
export async function fetchResetCredits(id: string, signal?: AbortSignal) {
  return listSchema.parse(await request(base(id), { signal }));
}
export async function fetchResetCreditState(id: string, signal?: AbortSignal) {
  return stateSchema.parse(await request(base(id) + "/state", { signal }));
}
export async function consumeResetCredit(
  id: string,
  creditID: string | undefined,
  csrf: string,
  signal?: AbortSignal,
) {
  const value = z
    .object({
      code: z.string().max(64),
      windowsReset: z.number().int().min(0).max(128),
    })
    .parse(
      await request(base(id) + "/consume", {
        method: "POST",
        body: creditID === undefined ? {} : { creditID },
        csrf,
        signal,
        timeout: 35000,
      }),
    );
  return code.safeParse(value.code).data ?? "unknown";
}
export async function saveResetCreditSettings(
  id: string,
  revision: number,
  settings: ResetCreditState["settings"],
  csrf: string,
  signal?: AbortSignal,
) {
  return stateSchema.parse(
    await request(base(id) + "/settings", {
      method: "PUT",
      body: { revision, ...settings },
      csrf,
      signal,
    }),
  );
}
export function resetCreditMessage(code: ResetCreditCode): string {
  return {
    reset: "重置成功，已消耗一张重置卡。",
    nothing_to_reset: "当前没有可重置的用量，卡未消耗。",
    no_credit: "没有可用的重置卡，请重新读取列表。",
    already_redeemed: "该操作已处理，无需再次消耗重置卡。",
    unknown:
      "使用结果尚未确认。请核对上次操作；核对会沿用原请求编号，不会另选一张卡。",
  }[code];
}
