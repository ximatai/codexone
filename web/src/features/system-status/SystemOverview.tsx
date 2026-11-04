import { Badge, Button, Group, Stack, Text } from "@mantine/core";
import styles from "./system.module.css";
import { useEffect, useState } from "react";
import { fetchSystemStatus } from "./api";
import type { SystemStatus } from "./api";

type State =
  | { kind: "loading" }
  | { kind: "failed" }
  | { kind: "loaded"; data: SystemStatus };

const labels: Record<string, string> = {
  execution_store: "执行与用量存储",
  upstream_accounts: "上游账号",
  authorization: "访问授权",
};

export function SystemOverview({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [stale, setStale] = useState(false);
  const [revision, setRevision] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    fetchSystemStatus(controller.signal).then(
      (data) => {
        if (!controller.signal.aborted) {
          setStale(false);
          setState({ kind: "loaded", data });
        }
      },
      () => {
        if (!controller.signal.aborted) {
          setStale(true);
          setState((previous) =>
            previous.kind === "loaded" ? previous : { kind: "failed" },
          );
        }
      },
    );
    return () => controller.abort();
  }, [revision]);

  function reload() {
    setRevision((value) => value + 1);
  }

  if (compact)
    return (
      <Stack gap="xs" aria-label="服务状态">
        {stale && state.kind === "loaded" && (
          <Text size="xs" c="orange">
            服务状态已陈旧，保留上次成功快照。
          </Text>
        )}
        {state.kind === "loading" ? (
          <Text size="sm" role="status">
            正在连接服务…
          </Text>
        ) : state.kind === "failed" ? (
          <>
            <Text size="sm" role="alert">
              管理服务连接失败，无法确认生成状态。
            </Text>
            <Button size="xs" variant="light" onClick={reload}>
              重新连接
            </Button>
          </>
        ) : (
          <>
            <Group justify="space-between">
              <Text size="sm">管理服务</Text>
              <Badge color="green" variant="light">
                连接正常
              </Badge>
            </Group>
            <Group justify="space-between">
              <Text size="sm">生成服务</Text>
              <Badge
                color={state.data.ready ? "green" : "orange"}
                variant="light"
              >
                {state.data.ready ? "已就绪" : "未就绪"}
              </Badge>
            </Group>
            {!state.data.ready && (
              <Text size="xs" c="dimmed">
                {state.data.checks.some((check) => !check.ready)
                  ? `待就绪：${state.data.checks
                      .filter((check) => !check.ready)
                      .map((check) => labels[check.name] ?? check.name)
                      .join("、")}`
                  : "未提供就绪检查，暂无法确认生成可用。"}
              </Text>
            )}
            <Button size="xs" variant="subtle" onClick={reload}>
              刷新服务状态
            </Button>
          </>
        )}
      </Stack>
    );
  return (
    <div className={styles.root}>
      <section>
        <h1>连接与运行状态</h1>
      </section>
      <section className={styles.panel} aria-label="服务状态">
        {state.kind === "loading" && <p role="status">正在连接服务…</p>}
        {state.kind === "failed" && (
          <>
            <h2>无法连接服务</h2>
            <p role="alert">请检查服务连接后重试。</p>
            <button onClick={reload}>重新连接</button>
          </>
        )}
        {state.kind === "loaded" && (
          <>
            <div className={styles.heading}>
              <h2>网关{state.data.ready ? "已就绪" : "尚未就绪"}</h2>
              <span className={styles.badge}>连接正常</span>
            </div>
            <ul>
              {state.data.checks.map((check) => (
                <li key={check.name}>
                  <span>{labels[check.name] ?? check.name}</span>
                  <span className={check.ready ? styles.good : styles.subtle}>
                    {check.ready ? "已就绪" : "待就绪"}
                  </span>
                </li>
              ))}
            </ul>
            <button className={styles.secondary} onClick={reload}>
              刷新状态
            </button>
          </>
        )}
      </section>
    </div>
  );
}
