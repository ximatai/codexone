import {
  Alert,
  Badge,
  Button,
  Text,
  Skeleton,
  Stack,
  ThemeIcon,
} from "@mantine/core";
import { IconInbox, IconAlertTriangle } from "@tabler/icons-react";
import type { ReactNode } from "react";
export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <Stack align="center" gap="sm" py="xl">
      <ThemeIcon size={56} radius="xl" variant="light">
        <IconInbox size={26} />
      </ThemeIcon>
      <Text ta="center" c="dimmed">
        {children}
      </Text>
    </Stack>
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
    <Alert color="red" role="alert" icon={<IconAlertTriangle size={20} />}>
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

export function LoadingState({
  children = "正在读取…",
}: {
  children?: ReactNode;
}) {
  return (
    <Stack gap="sm" py="md" role="status">
      <Text size="sm" c="dimmed">
        {children}
      </Text>
      {[0, 1, 2].map((i) => (
        <Skeleton key={i} height={32} radius="sm" />
      ))}
    </Stack>
  );
}
