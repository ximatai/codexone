import { money } from "../../shared/presentation";
/** Integer arithmetic keeps values above Number.MAX_SAFE_INTEGER exact. */
export function compactCount(value: string | number | bigint): string {
  const count = BigInt(value);
  for (const [unit, label] of [
    [1000000000000n, "万亿"],
    [100000000n, "亿"],
    [10000n, "万"],
  ] as const) {
    if (count >= unit) {
      return formatCountUnit(count, unit, label);
    }
  }
  return count.toLocaleString("zh-CN");
}

export function compactKeyTokens(value: string): string {
  const count = BigInt(value);
  return count >= 10_000_000n
    ? formatCountUnit(count, 100_000_000n, "亿")
    : compactCount(count);
}

function formatCountUnit(count: bigint, unit: bigint, label: string): string {
  const hundredths = (count * 100n) / unit;
  const fraction = (hundredths % 100n)
    .toString()
    .padStart(2, "0")
    .replace(/0+$/, "");
  return `${hundredths / 100n}${fraction ? `.${fraction}` : ""} ${label}`;
}

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
