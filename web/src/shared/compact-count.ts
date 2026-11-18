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

export function compactKeyTokens(value: string | bigint): string {
  const count = BigInt(value);
  return count >= 10_000_000n
    ? formatCountUnit(count, 100_000_000n, "亿")
    : compactCount(count);
}

export function compactOverviewTokens(count: bigint): string {
  if (count < 10_000_000n) return compactCount(count);
  return count >= 1_000_000_000_000n
    ? formatCountUnit(count, 1_000_000_000_000n, "万亿", true)
    : formatCountUnit(count, 100_000_000n, "亿", true);
}

function formatCountUnit(
  count: bigint,
  unit: bigint,
  label: string,
  fixedDecimals = false,
): string {
  const hundredths = (count * 100n + (fixedDecimals ? unit / 2n : 0n)) / unit;
  const fraction = (hundredths % 100n).toString().padStart(2, "0");
  const decimals = fixedDecimals ? fraction : fraction.replace(/0+$/, "");
  return `${hundredths / 100n}${decimals ? `.${decimals}` : ""} ${label}`;
}
