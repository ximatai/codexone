import type { AccountName } from "../../shared/account-presentation";
import {
  Alert,
  Button,
  Anchor,
  Paper,
  Skeleton,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { IconAlertTriangle, IconAlertCircle } from "@tabler/icons-react";
import { Link } from "react-router";
import { ErrorState } from "../../shared/ui/States";
import {
  attentionMessage,
  attentionTarget,
  type AttentionItem,
} from "./attention-api";

export function AttentionPanel({
  items,
  loading,
  error,
  retry,
  accounts = [],
  release,
}: {
  items?: AttentionItem[];
  loading: boolean;
  error: boolean;
  retry: () => void;
  accounts?: readonly AccountName[];
  release?: (item: AttentionItem) => void;
}) {
  return (
    <Paper withBorder p="md" component="section" aria-label="需要处理">
      <Title order={2} size="h4" mb="sm">
        需要处理
      </Title>
      {error ? (
        <ErrorState retry={retry} retryLabel="重试读取提醒">
          需要处理的事项读取失败，请重试。
        </ErrorState>
      ) : loading ? (
        <Skeleton h={32} aria-label="正在读取提醒" />
      ) : !items?.length ? (
        <Text size="sm" c="dimmed">
          暂无需要处理的事项
        </Text>
      ) : (
        <Stack gap="xs">
          {items.map((item, index) => (
            <Alert
              key={`${item.kind}-${item.subjectID ?? "system"}-${index}`}
              color={item.severity === "critical" ? "red" : "yellow"}
              icon={
                item.severity === "critical" ? (
                  <IconAlertCircle size={18} />
                ) : (
                  <IconAlertTriangle size={18} />
                )
              }
              aria-label={
                item.severity === "critical" ? "紧急事项" : "提醒事项"
              }
            >
              <Anchor
                className="wrap-anywhere"
                component={Link}
                to={attentionTarget(item)}
                c="inherit"
                size="sm"
              >
                {attentionMessage(item, accounts)} ›
              </Anchor>
              {item.kind === "unresolved_executions" && release && (
                <Button
                  size="xs"
                  variant="light"
                  ml="sm"
                  disabled={
                    typeof item.detail.count !== "number" ||
                    item.detail.count <= 0
                  }
                  onClick={() => release(item)}
                >
                  核对并释放
                </Button>
              )}
            </Alert>
          ))}
        </Stack>
      )}
    </Paper>
  );
}
