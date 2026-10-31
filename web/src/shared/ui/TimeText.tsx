import { localTime, timeTitle, money, moneyThreshold } from "../presentation";
export function TimeText({
  value,
  mode = "local",
  now = Date.now(),
}: {
  value: number | null | undefined;
  mode?: "local" | "utc" | "relative";
  now?: number;
}) {
  if (value == null) return <span>不可用</span>;
  const delta = Math.round((value * 1000 - now) / 60000);
  const text =
    mode === "local"
      ? localTime(value)
      : mode === "utc"
        ? new Date(value * 1000)
            .toISOString()
            .replace("T", " ")
            .replace(".000Z", " UTC")
        : new Intl.RelativeTimeFormat("zh-CN", { numeric: "auto" }).format(
            delta,
            "minute",
          );
  return (
    <time
      dateTime={new Date(value * 1000).toISOString()}
      title={timeTitle(value)}
    >
      {text}
    </time>
  );
}
export function MoneyText({
  value,
  unlimited = false,
  threshold = false,
}: {
  value: string | number | null | undefined;
  unlimited?: boolean;
  threshold?: boolean;
}) {
  return (
    <span>
      {threshold
        ? value == null
          ? unlimited
            ? "不限"
            : "不可用"
          : moneyThreshold(Number(value))
        : money(value, unlimited)}
    </span>
  );
}
