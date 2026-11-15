import { Box, Group, Paper, Title } from "@mantine/core";
import { useId, type ReactNode } from "react";
import styles from "./usage.module.css";

export function UsageChartCard({
  title,
  caption,
  children,
}: {
  title: string;
  caption: ReactNode;
  children: ReactNode;
}) {
  const heading = useId();
  return (
    <Paper
      withBorder
      p={{ base: "sm", sm: "md" }}
      component="section"
      className={styles.chartCard}
      aria-labelledby={heading}
    >
      <Group align="baseline" justify="space-between" gap="xs" mb="sm">
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
