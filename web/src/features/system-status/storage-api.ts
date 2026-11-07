import { request } from "../../shared/management";
import { z } from "../../shared/schema";
const backupSchema = z.object({
  enabled: z.boolean(),
  lastSuccessUnixSeconds: z.number().nullable().optional(),
  retainedCount: z.number().int().nonnegative(),
});
const resourceSchema = z.object({
  unixSeconds: z.number().int().nonnegative(),
  processResidentBytes: z.number().nonnegative().optional(),
  hostAvailableBytes: z.number().nonnegative().optional(),
  hostTotalBytes: z.number().positive().optional(),
  hostCPUPercent: z.number().min(0).max(100).optional(),
  hostLoadAverage1m: z.number().nonnegative().optional(),
});
export type ResourceSample = z.infer<typeof resourceSchema>;
export async function fetchStorage(
  signal: AbortSignal,
): Promise<ReturnType<typeof parseStorage>> {
  const value = (await request("/api/runtime/storage", { signal })) as Record<
    string,
    unknown
  >;
  return parseStorage(value);
}
export function parseStorage(value: Record<string, unknown>): Record<
  string,
  unknown
> & {
  admissionAllowed: boolean;
  optionalWorkAllowed: boolean;
  pressure: string;
  resources?: ResourceSample[];
  backup?: z.infer<typeof backupSchema>;
} {
  if (
    typeof value.admissionAllowed !== "boolean" ||
    typeof value.optionalWorkAllowed !== "boolean" ||
    typeof value.pressure !== "string"
  )
    throw new Error("invalid storage response");
  return {
    ...value,
    admissionAllowed: value.admissionAllowed,
    optionalWorkAllowed: value.optionalWorkAllowed,
    pressure: value.pressure,
    resources: z.array(resourceSchema).max(121).safeParse(value.resources).data,
    backup: value.backup == null ? undefined : backupSchema.parse(value.backup),
  };
}
