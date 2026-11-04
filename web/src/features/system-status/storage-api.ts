import { request } from "../../shared/management";
import { z } from "../../shared/schema";
const backupSchema = z.object({
  enabled: z.boolean(),
  lastSuccessUnixSeconds: z.number().nullable().optional(),
  retainedCount: z.number().int().nonnegative(),
});
export async function fetchStorage(
  signal: AbortSignal,
): Promise<
  Record<string, unknown> & { backup?: z.infer<typeof backupSchema> }
> {
  const value = (await request("/api/runtime/storage", { signal })) as Record<
    string,
    unknown
  >;
  return parseStorage(value);
}
export function parseStorage(value: Record<string, unknown>) {
  if (
    typeof value.admissionAllowed !== "boolean" ||
    typeof value.optionalWorkAllowed !== "boolean" ||
    typeof value.pressure !== "string"
  )
    throw new Error("invalid storage response");
  return {
    ...value,
    backup: value.backup == null ? undefined : backupSchema.parse(value.backup),
  };
}
