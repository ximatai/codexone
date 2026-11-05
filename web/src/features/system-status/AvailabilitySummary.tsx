import { Anchor, Badge, Group, Paper, Stack, Text } from "@mantine/core";
import { Link } from "react-router";
import type { CapacityMetric } from "./overview-format";
import type { Headroom } from "../../shared/governance-api";
import styles from "./overview.module.css";

export function AvailabilitySummary({
  ready,
  unreadable,
  accountCount,
  eligibleIDs,
  accountHeadroom,
  storageAllowed,
  capacities,
}: {
  ready?: boolean;
  unreadable: boolean;
  accountCount?: number;
  eligibleIDs?: string[];
  accountHeadroom?: Headroom["accounts"];
  storageAllowed?: boolean;
  capacities?: CapacityMetric[];
}) {
  const blocked = capacities?.some(
    (item) =>
      item.blocking &&
      item.current != null &&
      BigInt(item.current) >= BigInt(item.limit),
  );
  const noAccount =
    accountCount != null && accountCount > 0 && eligibleIDs?.length === 0;
  const concurrency = eligibleIDs?.map((id) =>
    accountHeadroom?.find((item) => item.id === id),
  );
  const knownFree =
    concurrency?.filter(
      (item) => item && (!item.blocking || item.current < item.limit),
    ).length ?? 0;
  const full =
    !!concurrency?.length &&
    concurrency.every((item) => item != null) &&
    knownFree === 0;
  const unknown =
    unreadable ||
    ready == null ||
    !accountCount ||
    storageAllowed == null ||
    !knownFree ||
    !capacities ||
    capacities.some((item) => item.blocking && item.current == null);
  const title = unreadable
    ? "当前可用性无法确认"
    : ready === false ||
        storageAllowed === false ||
        blocked ||
        noAccount ||
        full
      ? "当前存在接入阻断"
      : unknown
        ? "当前可用性无法确认"
        : "本地准入条件正常";
  return (
    <Paper
      withBorder
      p="md"
      component="section"
      aria-label="当前接入条件"
      className={styles.availability}
    >
      <Stack gap="xs">
        <Group justify="space-between">
          <Text fw={600}>现在能否继续使用</Text>
          <Badge color={title === "本地准入条件正常" ? "green" : "orange"}>
            {title}
          </Badge>
        </Group>
        <Text size="sm">
          {unreadable
            ? "部分来源读取失败或陈旧，请先核对读取状态。"
            : ready === false
              ? "生成服务尚未就绪，请查看服务状态。"
              : storageAllowed === false
                ? "存储当前暂停准入，请查看存储状态。"
                : noAccount
                  ? "已配置账号当前均有授权、冷却或模式限制。"
                  : full
                    ? "符合资格的账号均已达到本地并发上限，请等待在途请求结束。"
                    : blocked
                      ? "本地治理容量已到阻断上限，请查看资源使用。"
                      : unknown
                        ? "账号或治理余量尚未完整确认。"
                        : `${knownFree} 个账号满足当前本地资格检查且仍有并发名额。`}
        </Text>
        <Text size="xs" c="dimmed">
          本地就绪与准入条件汇总；订阅额度、具体模型和请求结果请结合详情核对。
        </Text>
        <Group gap="md">
          <Anchor component={Link} size="xs" to="/accounts">
            检查订阅账号
          </Anchor>
          <Anchor component={Link} size="xs" to="/?storage=details">
            检查存储
          </Anchor>
          <Anchor component={Link} size="xs" to="/usage">
            查看用量与诊断
          </Anchor>
        </Group>
      </Stack>
    </Paper>
  );
}
