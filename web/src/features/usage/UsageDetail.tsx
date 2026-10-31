import {
  Button,
  CopyButton,
  Drawer,
  Paper,
  Title,
  Stack,
  Text,
} from "@mantine/core";
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
  estimateNote,
} from "../../shared/presentation";
function number(value: string | null | undefined, lower = false) {
  return value == null
    ? "不可用"
    : (lower ? "≥ " : "") + BigInt(value).toLocaleString("zh-CN");
}
function utc(value: number) {
  return new Date(value * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(".000Z", " UTC");
}
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
      title="请求详情"
      position="right"
      size="lg"
      closeButtonProps={{ "aria-label": "关闭" }}
    >
      {detail && (
        <Stack>
          <Paper withBorder p="md">
            <Stack gap="sm">
              <Title order={3}>基本信息</Title>
              <Text className="wrap-anywhere">
                请求 ID：{detail.requestID ?? detail.id}
              </Text>
              <CopyButton
                key={detail.requestID ?? detail.id}
                value={detail.requestID ?? detail.id}
              >
                {({ copied, copy }) => (
                  <>
                    <Button onClick={copy}>复制请求 ID</Button>
                    {copied && <Text role="status">已复制请求 ID</Text>}
                  </>
                )}
              </CopyButton>
              <Text size="xs" c="dimmed">
                无法复制时，可手动选择上方请求 ID。
              </Text>
              <Text title={timeTitle(detail.atUnixSeconds)}>
                {localTime(detail.atUnixSeconds)} / {utc(detail.atUnixSeconds)}
              </Text>
              <Text>
                Key：{detail.principal ?? "主体未记录"} · {detail.keyID}
              </Text>
              <Text>
                账号：{detail.accountID ?? "未派发"} · 模型：
                {detail.model ?? "未记录"} · {modes[detail.mode]}
              </Text>
              <Text>
                结果：{detail.outcome ? outcomes[detail.outcome] : "未记录"} ·{" "}
                {detail.state ? states[detail.state] : "无执行租约"}
              </Text>
              <Text>
                错误：
                {detail.failure
                  ? (failures[detail.failure] ?? "其他异常")
                  : "无已记录错误"}
              </Text>
            </Stack>
          </Paper>
          <Paper withBorder p="md">
            <Stack gap="sm">
              <Title order={3}>性能表现</Title>
              <Text>
                首事件耗时：
                {detail.firstEventMilliseconds == null
                  ? "不可用"
                  : `${detail.firstEventMilliseconds} ms`}{" "}
                · 总耗时：
                {detail.totalMilliseconds == null
                  ? "不可用"
                  : `${detail.totalMilliseconds} ms`}
              </Text>
              <Text size="sm">
                耗时从准入后开始观测；历史记录或无首事件时不可用。{estimateNote}
                。
              </Text>
            </Stack>
          </Paper>
          <Paper withBorder p="md">
            <Stack gap="sm">
              <Title order={3}>Token 与用量证据</Title>
              <Text>
                用量：
                {detail.completeness === "complete"
                  ? "完整"
                  : detail.completeness === "partial"
                    ? "部分证据，数值为下界"
                    : "不可用"}
              </Text>
              {Object.entries(metricLabels).map(([key, label]) => (
                <Text key={key}>
                  {label}：
                  {key === "estimatedMicros"
                    ? money(detail.metrics.estimatedMicros)
                    : number(
                        detail.metrics[key as keyof Metrics],
                        detail.completeness === "partial",
                      )}
                </Text>
              ))}
            </Stack>
          </Paper>
        </Stack>
      )}
    </Drawer>
  );
}
