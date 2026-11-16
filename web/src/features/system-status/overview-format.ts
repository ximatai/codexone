import { money } from "../../shared/presentation";
export function compactMoney(value: string): string {
  return BigInt(value) > 0n && BigInt(value) < 10000n
    ? `$0.${value.padStart(6, "0").replace(/0+$/, "")}`
    : money(value).replace("估算 ", "");
}
export interface CapacityMetric {
  name: string;
  current: string | null;
  limit: string;
  blocking: boolean;
}
