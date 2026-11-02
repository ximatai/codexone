import { request } from "./management";
import { z } from "./schema";

const numeric = z.string().regex(/^(0|[1-9][0-9]*)$/);
const schema = z.object({
  capacities: z.array(
    z.object({
      name: z.string(),
      current: numeric.nullable(),
      limit: numeric,
      blocking: z.boolean(),
    }),
  ),
  accounts: z
    .array(
      z.object({
        id: z.string(),
        current: z.number(),
        peak24Hours: z.number(),
        limit: z.number(),
        blocking: z.boolean(),
      }),
    )
    .max(64),
  unknownReconciliation: z.object({
    count: z.number().int().nonnegative(),
    beforeUnixSeconds: z.number().int().nonnegative(),
    periodSeconds: z.number(),
  }),
});
export async function fetchHeadroom(signal: AbortSignal) {
  return schema.parse(await request("/api/usage/headroom", { signal }));
}

export type Headroom = z.infer<typeof schema>;
