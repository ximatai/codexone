import { Badge, Button, Group, Text } from "@mantine/core";
import * as api from "./api";
import type { useKeys } from "./useKeys";
import type { KeyUsage } from "../usage/api";
import { DataTable, type DataColumn } from "../../shared/ui/DataTable";
import { StatusBadge } from "../../shared/ui/States";
import { TimeText } from "../../shared/ui/TimeText";
import { KeyName } from "../../shared/KeyName";
export function KeyList({
  keys,
  state,
  usage,
  onDetails,
  highlightedID,
}: {
  keys: api.ManagedKey[];
  state: ReturnType<typeof useKeys>;
  usage: { data?: KeyUsage[]; isError?: boolean; isPending?: boolean };
  highlightedID?: string | null;
  onDetails: (key: api.ManagedKey) => void;
}) {
  const columns: DataColumn<api.ManagedKey>[] = [
    {
      id: "identity",
      title: "密钥",
      sortValue: (key) => key.displayName ?? key.principal,
      render: (key) => <KeyName {...key} stacked />,
    },
    {
      id: "permissions",
      title: "权限",
      render: (key) => (
        <Group gap={5}>
          <Badge variant="light" title={key.models?.join("、")}>
            {key.models === null ? "全部模型" : `${key.models.length} 个模型`}
          </Badge>
          {key.visionInput && <Badge variant="outline">视觉</Badge>}
          {key.imageGeneration && <Badge variant="outline">图片</Badge>}
        </Group>
      ),
    },
    {
      id: "status",
      title: "状态",
      render: (key) => {
        const expiry = api.expirationState(key.expiresAtUnixSeconds);
        return (
          <>
            <StatusBadge
              color={
                key.archivedAtUnixSeconds != null
                  ? "gray"
                  : expiry === "expired"
                    ? "red"
                    : key.enabled
                      ? "green"
                      : "gray"
              }
            >
              {key.archivedAtUnixSeconds != null
                ? "已归档"
                : expiry === "expired"
                  ? "已到期"
                  : key.enabled
                    ? "可用"
                    : "已禁用"}
            </StatusBadge>
            {key.archivedAtUnixSeconds == null &&
              key.enabled &&
              expiry === "soon" && (
                <Text size="xs" c="orange">
                  7 天内到期
                </Text>
              )}
          </>
        );
      },
    },
    {
      id: "usage",
      title: "今日 Token",
      render: (key) => {
        const summary = usage.isError
          ? undefined
          : usage.data?.find((item) => item.keyID === key.id);
        return (
          <>
            <Text size="sm">
              {summary?.tokens == null
                ? "不可用"
                : `${summary.tokenUsageIncomplete ? "≥ " : ""}${BigInt(summary.tokens).toLocaleString("zh-CN")}`}{" "}
              / {api.formatKeyLimit(key.limits.tokens)} Token
            </Text>
          </>
        );
      },
    },
    {
      id: "lastUsed",
      title: "最近使用",
      render: (key) => {
        const summary = usage.isError
          ? undefined
          : usage.data?.find((item) => item.keyID === key.id);
        return usage.isPending ? (
          "读取中"
        ) : !summary ? (
          "不可用"
        ) : summary.lastUsedAtUnixSeconds == null ? (
          "从未使用"
        ) : (
          <TimeText value={summary.lastUsedAtUnixSeconds} />
        );
      },
    },
    {
      id: "actions",
      title: "",
      render: (key) => (
        <Button variant="subtle" size="xs" onClick={() => onDetails(key)}>
          查看详情
        </Button>
      ),
    },
  ];
  return (
    <DataTable
      rows={keys}
      columns={columns}
      rowKey={(key) => key.id}
      highlightedID={highlightedID}
      rowLabel={(key) =>
        `访问密钥 ${key.displayName ?? key.principal} · ${key.id}`
      }
      loading={state.loading && state.readAt === null}
      error={state.readAt === null ? state.error || undefined : undefined}
      retry={state.reload}
      empty={
        state.keys.length
          ? "没有匹配的密钥。"
          : state.archived
            ? "暂无已归档密钥。"
            : "暂无未归档密钥。"
      }
    />
  );
}
