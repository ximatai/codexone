import { Group, Stack, Text, Title } from "@mantine/core";
import type { ReactNode } from "react";
export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
}) {
  return (
    <Group justify="space-between" mb="xl">
      <Stack gap="xs">
        <Title order={1}>{title}</Title>
        {description && <Text c="dimmed">{description}</Text>}
      </Stack>
      {actions}
    </Group>
  );
}
