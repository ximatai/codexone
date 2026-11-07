import { ContinuousValue } from "../../shared/ui/ContinuousValue";
import { useEffect, useState } from "react";
import styles from "./accounts.module.css";
import { Progress, Stack, Text } from "@mantine/core";
import type { QuotaWindow } from "./observation-api";
import { resetIn, timeTitle } from "../../shared/presentation";
export function QuotaWindowBar({
  title,
  value,
  showUsed = false,
}: {
  title: string;
  value: QuotaWindow | null;
  showUsed?: boolean;
}) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60000);
    return () => clearInterval(timer);
  }, []);
  const duration = value?.durationSeconds;
  const reset = value?.resetsAtUnixSeconds;
  const secondsLeft = reset == null ? null : reset - now / 1000;
  const pace =
    showUsed &&
    duration != null &&
    duration > 0 &&
    secondsLeft != null &&
    secondsLeft > 0 &&
    secondsLeft <= duration
      ? 100 * (1 - secondsLeft / duration)
      : null;
  const difference =
    pace == null || value?.usedPercent == null
      ? null
      : Number((value.usedPercent - pace).toFixed(1));

  const remaining =
    value?.usedPercent == null ? null : Math.max(0, 100 - value.usedPercent);
  return (
    <Stack gap={3} mb="xs" className={styles.quotaWindow}>
      <Text size="xs">{title}</Text>
      <Text size={showUsed ? "sm" : "xl"} fw={700}>
        <ContinuousValue
          text={
            remaining === null
              ? "比例未提供"
              : showUsed
                ? `${value?.usedPercent}% 已用`
                : `剩余 ${remaining}%`
          }
        />
      </Text>
      {remaining !== null && (
        <div className={styles.quotaTrack}>
          <Progress
            aria-label={`${title}${showUsed ? "已用" : "剩余"}比例`}
            value={showUsed ? 100 - remaining : remaining}
            color={remaining > 30 ? "green" : remaining > 10 ? "yellow" : "red"}
          />
          {pace != null && (
            <svg
              className={styles.quotaPaceMarker}
              viewBox="0 0 100 12"
              preserveAspectRatio="none"
              aria-hidden="true"
            >
              <line
                x1={pace}
                x2={pace}
                y1="0"
                y2="12"
                vectorEffect="non-scaling-stroke"
              />
            </svg>
          )}
        </div>
      )}
      {pace != null && difference != null && (
        <Text
          size="xs"
          c={difference > 0 ? "orange.8" : "dimmed"}
          title="参考进度按本额度窗口已过去的时间线性计算。"
        >
          参考 {pace.toFixed(1)}%{" · "}
          {difference === 0
            ? "与参考持平"
            : `${difference > 0 ? "超出" : "低于"} ${Math.abs(difference).toFixed(1)} 个百分点`}
        </Text>
      )}
      <Text size="xs" c="dimmed" title={timeTitle(value?.resetsAtUnixSeconds)}>
        {resetIn(value?.resetsAtUnixSeconds ?? null, now)}
      </Text>
    </Stack>
  );
}
