import { KeyName } from "../../shared/KeyName";
import {
  ActionIcon,
  Code,
  Drawer,
  Group,
  Paper,
  Title,
  Stack,
  Text,
  Tooltip,
} from "@mantine/core";
import { IconCopy, IconCheck } from "@tabler/icons-react";
import { useState } from "react";
import type { Metrics, UsageReport } from "./api";
import {
  failures,
  modes,
  states,
  outcomes,
  metricLabels,
  money,
  localTime,
  timeTitle,
} from "../../shared/presentation";
import { duration, number } from "./format";
import styles from "./usage.module.css";
export function UsageDetail({
  detail,
  onClose,
}: {
  detail: UsageReport["rows"][number] | null;
  onClose: () => void;
}) {
  return (
    <Drawer
      removeScrollProps={{ removeScrollBar: false }}
      data-ui-overlay={detail ? "true" : undefined}
      opened={!!detail}
      onClose={onClose}
      title={
        <Text component="span" size="xl" fw={700}>
          请求详情
        </Text>
      }
      position="right"
      size="lg"
      closeButtonProps={{ "aria-label": "关闭" }}
    >
      {detail && (
        <Stack>
          <Paper withBorder p="md">
            <Title order={3} size="h5" mb="md">
              基本信息
            </Title>
            <dl className={styles.detailGrid}>
              <dt>请求 ID</dt>
              <dd>
                <Group gap="xs" wrap="nowrap">
                  <Code className="wrap-anywhere">
                    {detail.requestID ?? detail.id}
                  </Code>
                  <CopyRequestID
                    key={detail.requestID ?? detail.id}
                    value={detail.requestID ?? detail.id}
                  />
                </Group>
              </dd>
              {[
                [
                  "开始时间",
                  <span title={timeTitle(detail.atUnixSeconds)}>
                    {localTime(detail.atUnixSeconds)}
                  </span>,
                ],
                [
                  "Key",
                  <span>
                    <KeyName {...detail} /> · {detail.keyID}
                  </span>,
                ],
                ["账号", detail.accountID ?? "未派发"],
                ["模型", detail.model ?? "未记录"],
                ["模式", modes[detail.mode]],
                ["结果", detail.outcome ? outcomes[detail.outcome] : "未记录"],
                [
                  "用量状态",
                  detail.state ? states[detail.state] : "无执行租约",
                ],
                [
                  "错误",
                  detail.failure
                    ? (failures[detail.failure] ?? "其他异常")
                    : "无已记录错误",
                ],
              ].map(([label, value]) => (
                <Group key={String(label)} display="contents">
                  <dt>{label}</dt>
                  <dd>{value}</dd>
                </Group>
              ))}
            </dl>
          </Paper>
          <Paper withBorder p="md">
            <Title order={3} size="h5" mb="md">
              性能表现
            </Title>
            <dl className={styles.detailGrid}>
              <dt>首事件耗时</dt>
              <dd>{duration(detail.firstEventMilliseconds)}</dd>
              <dt>总耗时</dt>
              <dd>{duration(detail.totalMilliseconds)}</dd>
            </dl>
            <Text size="xs" c="dimmed">
              耗时从准入后开始观测；历史记录或无首事件时不可用。
            </Text>
          </Paper>
          <Paper withBorder p="md">
            <Title order={3} size="h5" mb="md">
              Token 与用量证据
            </Title>
            <Text size="sm">
              用量：
              {detail.completeness === "complete"
                ? "完整"
                : detail.completeness === "partial"
                  ? "部分证据，数值为下界"
                  : "不可用"}
            </Text>
            <dl className={styles.detailGrid}>
              {Object.entries(metricLabels).map(([key, label]) => (
                <Group key={key} display="contents">
                  <dt>{label}</dt>
                  <dd>
                    {key === "estimatedMicros"
                      ? money(detail.metrics.estimatedMicros)
                      : number(
                          detail.metrics[key as keyof Metrics],
                          detail.completeness === "partial",
                        )}
                  </dd>
                </Group>
              ))}
            </dl>
          </Paper>
        </Stack>
      )}
    </Drawer>
  );
}

function CopyRequestID({ value }: { value: string }) {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  return (
    <Stack gap={2}>
      <Tooltip label={state === "copied" ? "已复制请求 ID" : "复制请求 ID"}>
        <ActionIcon
          variant="subtle"
          aria-label="复制请求 ID"
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(value);
              setState("copied");
            } catch {
              setState("failed");
            }
          }}
        >
          {state === "copied" ? (
            <IconCheck size={17} />
          ) : (
            <IconCopy size={17} />
          )}
        </ActionIcon>
      </Tooltip>
      {state === "copied" && (
        <span className="visually-hidden" role="status">
          已复制请求 ID
        </span>
      )}
      {state === "failed" && (
        <Text size="xs" c="red" role="alert">
          复制失败，请手动选择请求 ID 复制。
        </Text>
      )}
    </Stack>
  );
}
