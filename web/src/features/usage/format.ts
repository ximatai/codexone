export function duration(value: number | null | undefined) {
  return value == null
    ? "不可用"
    : value >= 1000
      ? `${(value / 1000).toFixed(1)} s`
      : `${value.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} ms`;
}
export function number(value: string | null | undefined, lower = false) {
  return value == null
    ? "不可用"
    : (lower ? "≥ " : "") + BigInt(value).toLocaleString("zh-CN");
}
export function utc(value: number) {
  return new Date(value * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(".000Z", " UTC");
}
