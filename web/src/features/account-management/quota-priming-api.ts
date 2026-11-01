import { z } from "../../shared/schema";
import { request } from "../../shared/management";
const schema = z.object({
  revision: z.number().int().positive(),
  settings: z.object({
    enabled: z.boolean(),
    model: z
      .string()
      .nullish()
      .transform((v) => v ?? null),
    message: z.string(),
  }),
  models: z.array(z.string()).max(32),
  defaultModel: z.string().nullable(),
  lastAttemptAt: z.number().nullable(),
  lastResult: z.string().nullable(),
  attention: z.string().nullable(),
});
export type PrimingState = z.infer<typeof schema>;
const base = (id: string) =>
  `/api/accounts/${encodeURIComponent(id)}/quota-priming`;
export async function fetchPriming(id: string, signal?: AbortSignal) {
  return schema.parse(await request(base(id), { signal }));
}
export async function savePriming(
  id: string,
  revision: number,
  settings: PrimingState["settings"],
  csrf: string,
  signal?: AbortSignal,
) {
  return schema.parse(
    await request(base(id), {
      method: "PUT",
      body: { revision, ...settings },
      csrf,
      signal,
    }),
  );
}
export const validPrimingMessage = (value: string) => {
  const count = [...value].length;
  return (
    count >= 1 &&
    count <= 200 &&
    !/[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u.test(value)
  );
};
export const primingResult = (result: string | null) =>
  result === "success"
    ? "完成"
    : result === "pending"
      ? "已准入，等待结果；不会自动重发"
      : result
        ? "失败或结果未知；等待新观察，不自动重发"
        : "尚无预热尝试";
