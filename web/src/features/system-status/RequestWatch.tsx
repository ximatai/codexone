import {
  Anchor,
  Button,
  Code,
  Group,
  NativeSelect,
  Paper,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { KeyName } from "../../shared/KeyName";
import { localTime, outcomes } from "../../shared/presentation";
import type { FlightRow, KeySummary } from "./round2-api";
import styles from "./overview.module.css";

type Watch =
  | { kind: "waiting"; key: string; seen: Set<string>; expires: number }
  | { kind: "request"; row: FlightRow; expires: number; interrupted: boolean };

export function RequestWatch({
  active,
  rows,
  keys,
  selection,
  clearSelection,
}: {
  active: boolean;
  rows: readonly FlightRow[];
  keys: readonly KeySummary[];
  selection: { row: FlightRow; revision: number } | null;
  clearSelection: () => void;
}) {
  const [key, setKey] = useState("");
  const [watch, setWatch] = useState<Watch | null>(null);
  const [notice, setNotice] = useState("");
  const [now, setNow] = useState(Date.now());
  const observing = watch !== null;
  useEffect(() => {
    if (!observing) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [observing]);
  useEffect(() => {
    if (!selection) return;
    const at = Date.now();
    setNow(at);
    setNotice("");
    setWatch({
      kind: "request",
      row: selection.row,
      expires: at + 600_000,
      interrupted: !active,
    });
    clearSelection();
  }, [selection, active, clearSelection]);
  useEffect(() => {
    if (!watch) return;
    if (now >= watch.expires) {
      setNotice(
        watch.kind === "waiting"
          ? "关注已超时，2 分钟内没有捕获到新请求。"
          : "固定观察已结束，页面不再保留该请求快照。",
      );
      setWatch(null);
      return;
    }
    if (watch.kind === "waiting") {
      if (!active) {
        setNotice("观察已中断，未捕获新请求；恢复实时连接后可重新关注。");
        setWatch(null);
        return;
      }
      const row = rows.find(
        (row) =>
          !watch.seen.has(row.id) && (!watch.key || row.keyID === watch.key),
      );
      if (row)
        setWatch({
          kind: "request",
          row,
          expires: Date.now() + 600_000,
          interrupted: false,
        });
      return;
    }
    if (watch.row.outcome) return;
    const row = active
      ? rows.find((row) => row.id === watch.row.id)
      : undefined;
    if (row && (row !== watch.row || watch.interrupted))
      setWatch({ ...watch, row, interrupted: false });
    else if ((!active || !row) && !watch.interrupted)
      setWatch({ ...watch, interrupted: true });
  }, [active, rows, now, watch]);
  return (
    <Paper withBorder p="md" component="section" aria-label="请求关注">
      <Stack gap="xs">
        <Title order={3} size="h4">
          请求关注
        </Title>
        <Group align="end">
          <NativeSelect
            label="关注范围"
            disabled={watch?.kind === "waiting"}
            value={key}
            onChange={(event) => setKey(event.currentTarget.value)}
            data={[
              { value: "", label: "任意 Key" },
              ...keys.map((item) => ({
                value: item.keyID,
                label: `${item.displayName || item.principal || "Key"} · ${item.keyID.slice(-8)}`,
              })),
            ]}
          />
          <Button
            variant="light"
            disabled={!active || watch?.kind === "waiting"}
            onClick={() => {
              const at = Date.now();
              setNow(at);
              setNotice("");
              setWatch({
                kind: "waiting",
                key,
                seen: new Set(rows.map((row) => row.id)),
                expires: at + 120_000,
              });
            }}
          >
            关注下一次请求
          </Button>
          {watch && (
            <Button
              variant="subtle"
              onClick={() => {
                setWatch(null);
                setNotice("已结束关注。");
              }}
            >
              结束关注
            </Button>
          )}
          {!watch && notice && (
            <Button variant="subtle" onClick={() => setNotice("")}>
              收起提示
            </Button>
          )}
        </Group>
        <Text size="xs" c="dimmed">
          关注后新出现的一条请求，最多等待 2
          分钟；不发送测试调用。也可在请求行选择固定观察。
        </Text>
        {!active && (
          <Text size="xs" c="orange">
            实时活动观察不可用；仍可固定查看已有请求。
          </Text>
        )}
        <div className={watch || notice ? styles.watchResult : undefined}>
          {notice && (
            <Text size="sm" role="status">
              {notice}
            </Text>
          )}
          {watch?.kind === "waiting" && (
            <Text size="sm">
              正在等待新请求 · 剩余{" "}
              {Math.max(0, Math.ceil((watch.expires - now) / 1000))} 秒
            </Text>
          )}
          {watch?.kind === "request" && (
            <Stack gap={4}>
              <Group justify="space-between">
                <KeyName {...watch.row} />
                <Text size="sm" role="status">
                  {watch.row.outcome
                    ? (outcomes[watch.row.outcome] ??
                      (watch.row.outcome === "unknown"
                        ? "结果未明"
                        : watch.row.outcome))
                    : watch.interrupted
                      ? "观察中断，结果尚未确认"
                      : watch.row.hasFirstEvent == null
                        ? "首事件未观测"
                        : watch.row.hasFirstEvent
                          ? "已收到首个上游事件"
                          : "等待首个上游事件"}
                </Text>
              </Group>
              <Code className="wrap-anywhere">{watch.row.id}</Code>
              {watch.row.accountID && (
                <Anchor
                  component={Link}
                  size="sm"
                  to={`/?account=${encodeURIComponent(watch.row.accountID)}`}
                >
                  订阅账号：
                  {watch.row.accountDisplayName ?? watch.row.accountID}
                </Anchor>
              )}
              <Text size="xs">
                {watch.row.model ?? "模型未记录"} ·{" "}
                {watch.row.startedAtUnixSeconds == null
                  ? "开始时间未记录"
                  : localTime(watch.row.startedAtUnixSeconds)}
              </Text>
              <Text size="xs" c="dimmed">
                首事件不代表输出完成；活动消失不会推断为成功。快照最多保留 10
                分钟，离开首页清理。
              </Text>
              <Group>
                <Button
                  size="compact-xs"
                  variant="subtle"
                  onClick={async () => {
                    try {
                      if (!navigator.clipboard)
                        throw new Error("clipboard_unavailable");
                      await navigator.clipboard.writeText(watch.row.id);
                      setNotice("请求 ID 已复制。");
                    } catch {
                      setNotice("复制失败，可选中上方请求 ID 手动复制。");
                    }
                  }}
                >
                  复制请求 ID
                </Button>
                <Anchor
                  component={Link}
                  size="sm"
                  to={`/usage?${new URLSearchParams({ key: watch.row.keyID, range: "24h" })}`}
                >
                  按 Key 查看用量与诊断
                </Anchor>
              </Group>
            </Stack>
          )}
        </div>
      </Stack>
    </Paper>
  );
}
