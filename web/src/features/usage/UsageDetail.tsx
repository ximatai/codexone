import { useEffect, useState } from "react";
import { Button, Drawer, Stack, Text } from "@mantine/core";
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
  const [copied, setCopied] = useState("");
  useEffect(() => {
    setCopied("");
  }, [detail]);
  useEffect(() => {
    if (!detail) return;
    document.body.classList.add("management-overlay-open");
    return () => document.body.classList.remove("management-overlay-open");
  }, [detail]);
  return (
    <Drawer
      lockScroll={false}
      opened={!!detail}
      onClose={() => {
        onClose();
        setCopied("");
      }}
      title="请求详情"
      position="right"
      size="lg"
      closeButtonProps={{ "aria-label": "关闭" }}
    >
      {detail && (
        <Stack>
          <Text className="wrap-anywhere">
            请求 ID：{detail.requestID ?? detail.id}
          </Text>
          <Button
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(
                  detail.requestID ?? detail.id,
                );
                setCopied("已复制请求 ID");
              } catch {
                setCopied("复制失败，请手动选择请求 ID");
              }
            }}
          >
            复制请求 ID
          </Button>
          {copied && <Text role="status">{copied}</Text>}
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
            耗时从准入后开始观测；历史记录或无首事件时不可用。{estimateNote}。
          </Text>
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
      )}
    </Drawer>
  );
}
