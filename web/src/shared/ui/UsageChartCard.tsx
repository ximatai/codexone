import { Box, Group, Paper, Title } from "@mantine/core";
import { useId, type ReactNode } from "react";
import styles from "./usage-charts.module.css";

export function UsageChartCard({
  title,
  caption,
  children,
  className,
}: {
  title: string;
  caption: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  const heading = useId();
  return (
    <Paper
      withBorder
      component="section"
      className={
        className ? `${styles.chartCard} ${className}` : styles.chartCard
      }
      aria-labelledby={heading}
    >
      <Group
        align="baseline"
        justify="space-between"
        gap="xs"
        mb="sm"
        className={styles.chartHeader}
      >
        <Title order={3} size="h5" id={heading}>
          {title}
        </Title>
        <Box fz="xs" c="dimmed">
          {caption}
        </Box>
      </Group>
      {children}
    </Paper>
  );
}
