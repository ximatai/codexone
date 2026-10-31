import { useEffect, useState } from "react";
import styles from "./accounts.module.css";
import { Progress, Stack, Text } from "@mantine/core";
import type { QuotaWindow } from "./observation-api";
import { resetIn, timeTitle } from "../../shared/presentation";
export function QuotaWindowBar({
  title,
  value,
}: {
  title: string;
  value: QuotaWindow | null;
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
      <Text size="xl" fw={700}>
        {remaining === null ? "比例未提供" : `剩余 ${remaining}%`}
      </Text>
      {remaining !== null && (
        <Progress
          aria-label={`${title}剩余比例`}
          value={remaining}
          color={remaining > 30 ? "green" : remaining > 10 ? "yellow" : "red"}
        />
      )}
      <Text size="xs" c="dimmed" title={timeTitle(value?.resetsAtUnixSeconds)}>
        {resetIn(value?.resetsAtUnixSeconds ?? null, now)}
      </Text>
    </Stack>
  );
}
