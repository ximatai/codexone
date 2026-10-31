import { Alert, Badge, Button, Text } from "@mantine/core";
import type { ReactNode } from "react";
export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <Text ta="center" c="dimmed" py="xl">
      {children}
    </Text>
  );
}
export function ErrorState({
  children,
  retry,
  retryLabel = "重试",
}: {
  children: ReactNode;
  retry: () => void;
  retryLabel?: string;
}) {
  return (
    <Alert color="red" role="alert">
      {children}
      <Button variant="subtle" onClick={retry}>
        {retryLabel}
      </Button>
    </Alert>
  );
}
export function StatusBadge({
  children,
  color = "green",
}: {
  children: ReactNode;
  color?: string;
}) {
  return (
    <Badge variant="light" color={color}>
      {children}
    </Badge>
  );
}
