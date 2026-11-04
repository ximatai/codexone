import styles from "./overview.module.css";
import type { AccountName } from "../../shared/account-presentation";
import { useRef, useState } from "react";
import {
  Group,
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
  aggregateErrors = false,
  inlineAccounts = false,
  continuous = false,
}: {
  items?: AttentionItem[];
  loading: boolean;
  error: boolean;
  retry: () => void;
  accounts?: readonly AccountName[];
  release?: (item: AttentionItem) => void;
  aggregateErrors?: boolean;
  inlineAccounts?: boolean;
  continuous?: boolean;
}) {
  const toggle = useRef<HTMLButtonElement>(null);
  const [expanded, setExpanded] = useState(false);
  const critical =
    items?.filter((item) => item.severity === "critical").length ?? 0;
  const ordered = [...(items ?? [])].sort(
    (a, b) =>
      Number(b.severity === "critical") - Number(a.severity === "critical"),
  );
  return (
    <Paper withBorder p="md" component="section" aria-label="需要处理">
      <Group justify="space-between" mb="xs">
        <Title order={2} size="h4">
          需要处理
        </Title>
        {!loading && !error && !!items?.length && (
          <Text size="sm">
            共 {items.length} 项 · 紧急 {critical} 项 · 提醒{" "}
            {items.length - critical} 项
          </Text>
        )}
      </Group>
      {error && aggregateErrors ? (
        <Text size="sm" c="dimmed">
          提醒读取失败，请使用概览汇总重试。
        </Text>
      ) : error ? (
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
          <div
            className={
              continuous ? styles.attentionSlots : styles.attentionList
            }
            style={
              continuous
                ? {
                    height:
                      (expanded
                        ? ordered.length
                        : Math.min(5, ordered.length)) * 80,
                  }
                : undefined
            }
          >
            {(expanded ? ordered : ordered.slice(0, 5)).map((item, index) => (
              <Alert
                key={`${item.kind}-${item.subjectType}-${item.subjectID ?? "system"}-${String(item.detail.source ?? "")}`}
                className={continuous ? styles.attentionSlot : undefined}
                style={
                  continuous
                    ? { transform: `translateY(${index * 80}px)` }
                    : undefined
                }
                p={item.severity === "critical" ? "sm" : "6px 0"}
                variant={item.severity === "critical" ? "light" : "transparent"}
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
                  to={
                    inlineAccounts &&
                    item.subjectType === "account" &&
                    item.subjectID
                      ? `/?account=${encodeURIComponent(item.subjectID)}`
                      : attentionTarget(item)
                  }
                  c="inherit"
                  size="sm"
                >
                  {continuous
                    ? attentionMessage(item, accounts)
                        .split(/([0-9][0-9.,%]*)/g)
                        .map((part, index) =>
                          /^[0-9]/.test(part) ? (
                            <span
                              className={styles.attentionNumber}
                              key={index}
                            >
                              {part}
                            </span>
                          ) : (
                            part
                          ),
                        )
                    : attentionMessage(item, accounts)}{" "}
                  ›
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
          </div>
          {items.length > 5 && (
            <Button
              variant="subtle"
              ref={toggle}
              onClick={() => {
                setExpanded((value) => !value);
                if (expanded)
                  requestAnimationFrame(() => {
                    toggle.current?.scrollIntoView({ block: "center" });
                    toggle.current?.focus({ preventScroll: true });
                  });
              }}
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
