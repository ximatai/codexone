import { KeyName } from "../../shared/KeyName";
import {
  accountName,
  type AccountName,
} from "../../shared/account-presentation";
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

const incompleteReasons = {
  max_output_tokens: "达到输出限制",
  max_messages: "达到消息数上限",
  content_filter: "内容过滤",
  steered: "上游按引导指令结束当前响应",
  unspecified: "原因未说明",
};
import styles from "./usage.module.css";
export function UsageDetail({
  detail,
  onClose,
  accounts = [],
}: {
  detail: UsageReport["rows"][number] | null;
  onClose: () => void;
  accounts?: readonly AccountName[];
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
                [
                  "账号",
                  detail.accountID
                    ? accountName(detail.accountID, accounts)
                    : "未派发",
                ],
                ["模型", detail.model ?? "未记录"],
                ["模式", modes[detail.mode]],
                [
                  "请求推理强度",
                  detail.requestMetadataRecorded
                    ? (detail.reasoningEffort ?? "默认")
                    : "—",
                ],
                [
                  "请求服务档位",
                  detail.requestMetadataRecorded
                    ? (detail.serviceTier ?? "默认")
                    : "—",
                ],
                ["实际服务档位", detail.actualServiceTier ?? "—"],
                ["结果", detail.outcome ? outcomes[detail.outcome] : "未记录"],
                [
                  "用量状态",
                  detail.state ? states[detail.state] : "无执行租约",
                ],
                [
                  "错误",
                  detail.upstreamIncompleteReason
                    ? `上游未完成 · ${incompleteReasons[detail.upstreamIncompleteReason]}`
                    : detail.failure
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
                : "完整用量不可用，已有数值为下界"}
            </Text>
            {detail.outcome === "succeeded" &&
              detail.completeness !== "complete" && (
                <Text size="sm">响应已完成，用量待核对，无需重新生成。</Text>
              )}
            <Text size="sm">
              费用：
              {detail.metrics.priceCompleteness === "unavailable"
                ? "价格不可用"
                : (detail.metrics.priceCompleteness ?? detail.completeness) ===
                    "complete"
                  ? "已配置费率的完整估算"
                  : "部分费用为下界"}
            </Text>
            {detail.svgAuthorModel && (
              <Text size="sm">SVG 作者模型：{detail.svgAuthorModel}</Text>
            )}
            {(detail.usageMissingReasons ?? []).length > 0 && (
              <Text size="sm" c="dimmed">
                {(detail.usageMissingReasons ?? [])
                  .map(
                    (reason) =>
                      (
                        ({
                          svg_input_unavailable: "作者输入计数缺失",
                          svg_output_unavailable: "作者输出计数缺失",
                          svg_usage_ambiguous: "作者计量来源待核对",
                          svg_total_inconsistent: "作者计数总量不一致",
                          svg_price_unavailable: "作者费率未知",
                        }) as Record<string, string>
                      )[reason] ?? "部分计量信息不可用",
                  )
                  .join("；")}
              </Text>
            )}
            <dl className={styles.detailGrid}>
              {Object.entries(metricLabels).map(([key, label]) => (
                <Group key={key} display="contents">
                  <dt>{label}</dt>
                  <dd>
                    {key === "estimatedMicros"
                      ? `${(detail.metrics.priceCompleteness ?? detail.completeness) !== "complete" && detail.metrics.estimatedMicros != null ? "≥ " : ""}${money(detail.metrics.estimatedMicros)}`
                      : number(
                          detail.metrics[key as keyof Metrics],
                          detail.completeness !== "complete",
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
