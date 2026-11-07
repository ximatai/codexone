import { ContinuousValue } from "../../shared/ui/ContinuousValue";
import { useEffect, useState } from "react";
import styles from "./accounts.module.css";
import { Progress, Stack, Text } from "@mantine/core";
import type { QuotaWindow } from "./observation-api";
import { localTime, resetIn, timeTitle } from "../../shared/presentation";
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
        <Progress
          aria-label={`${title}${showUsed ? "已用" : "剩余"}比例`}
          value={showUsed ? 100 - remaining : remaining}
          color={remaining > 30 ? "green" : remaining > 10 ? "yellow" : "red"}
        />
      )}
      <Text size="xs" c="dimmed" title={timeTitle(value?.resetsAtUnixSeconds)}>
        {resetIn(value?.resetsAtUnixSeconds ?? null, now)}
        {showUsed && value?.resetsAtUnixSeconds != null && (
          <Text component="span" size="xs" display="block">
            {localTime(value.resetsAtUnixSeconds)}
          </Text>
        )}
      </Text>
    </Stack>
  );
}
