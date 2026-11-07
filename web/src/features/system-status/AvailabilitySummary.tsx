import { Alert, Anchor, Text } from "@mantine/core";
import { Link } from "react-router";
import type { CapacityMetric } from "./overview-format";
import type { Headroom } from "../../shared/governance-api";

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
  const reason = unreadable
    ? null
    : storageAllowed === false
      ? {
          text: "存储当前暂停准入。",
          to: "/?storage=details",
          link: "检查存储",
        }
      : ready === false || noAccount
        ? {
            text: noAccount ? "当前没有可用的订阅账号。" : "生成服务尚未就绪。",
            to: "/accounts",
            link: "检查订阅账号",
          }
        : blocked
          ? {
              text: "本地治理容量已到阻断上限。",
              to: "/usage",
              link: "查看用量与诊断",
            }
          : full
            ? {
                text: "可用账号的并发名额已满，请等待在途请求结束。",
                to: "/accounts",
                link: "查看订阅账号",
              }
            : null;
  if (reason)
    return (
      <Alert color="orange" title="当前存在接入阻断" role="status">
        {reason.text}{" "}
        <Anchor component={Link} to={reason.to} size="sm">
          {reason.link}
        </Anchor>
      </Alert>
    );
  return unknown ? (
    <Text size="xs" c="dimmed" role="status">
      当前可用性无法确认
    </Text>
  ) : null;
}
