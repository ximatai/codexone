import type { AccountName } from "../../shared/account-presentation";
import { useState } from "react";
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
  const [expanded, setExpanded] = useState(false);
  const critical =
    items?.filter((item) => item.severity === "critical").length ?? 0;
  const ordered = [...(items ?? [])].sort(
    (a, b) =>
      Number(b.severity === "critical") - Number(a.severity === "critical"),
  );
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
          <Text size="sm">
            共 {items.length} 项 · 紧急 {critical} 项 · 提醒{" "}
            {items.length - critical} 项
          </Text>
          <Text size="xs" c="dimmed">
            账号 {items.filter((item) => item.subjectType === "account").length}{" "}
            项 · Key {items.filter((item) => item.subjectType === "key").length}{" "}
            项 · 系统与协议{" "}
            {
              items.filter(
                (item) =>
                  item.subjectType !== "account" && item.subjectType !== "key",
              ).length
            }{" "}
            项
          </Text>
          {(expanded ? ordered : ordered.slice(0, 5)).map((item, index) => (
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
          {items.length > 5 && (
            <Button
              variant="subtle"
              onClick={() => setExpanded((value) => !value)}
              aria-expanded={expanded}
            >
              {expanded ? "收起提醒" : `查看全部 ${items.length} 项`}
            </Button>
          )}
        </Stack>
      )}
    </Paper>
  );
}
