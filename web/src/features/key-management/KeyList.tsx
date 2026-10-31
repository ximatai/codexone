import { Badge, ActionIcon, Group, Menu, Text } from "@mantine/core";
import {
  IconChartBar,
  IconPencil,
  IconDots,
  IconClock,
  IconRefresh,
  IconBan,
  IconCheck,
} from "@tabler/icons-react";
import { Link } from "react-router";
import * as api from "./api";
import type { useKeys } from "./useKeys";
import type { KeyUsage } from "../usage/api";
import { DataTable, type DataColumn } from "../../shared/ui/DataTable";
import { StatusBadge } from "../../shared/ui/States";
import { TimeText, MoneyText } from "../../shared/ui/TimeText";
import { timeTitle } from "../../shared/presentation";
export function KeyList({
  keys,
  state,
  usage,
  setExpiring,
  setDisabling,
  toggle,
}: {
  keys: api.ManagedKey[];
  state: ReturnType<typeof useKeys>;
  usage: { data?: KeyUsage[] };
  setExpiring: (key: api.ManagedKey) => void;
  setDisabling: (key: api.ManagedKey) => void;
  toggle: (key: api.ManagedKey) => Promise<boolean>;
}) {
  const columns: DataColumn<api.ManagedKey>[] = [
    {
      id: "col0",
      title: "主体 / 标识",
      sortValue: (key) => key.principal,
      render: (key) => (
        <>
          <Text fw={600}>{key.principal}</Text>
          <Text size="xs" c="dimmed" className="identifier" title={key.id}>
            {key.id}
          </Text>
          <Text
            size="xs"
            c="dimmed"
            title={timeTitle(key.createdAtUnixSeconds)}
          >
            创建：
            <TimeText value={key.createdAtUnixSeconds} />
          </Text>
        </>
      ),
    },
    {
      id: "col1",
      title: "权限",
      render: (key) => (
        <>
          <Group gap={5}>
            {key.models.map((model) => (
              <Badge className="model-id" variant="light" key={model}>
                {model}
              </Badge>
            ))}
            {key.visionInput && <Badge variant="outline">视觉</Badge>}
            {key.imageGeneration && (
              <Badge variant="outline">图片生成 / 编辑</Badge>
            )}
          </Group>
        </>
      ),
    },
    {
      id: "col2",
      title: "状态",
      render: (key) => (
        <>
          <StatusBadge color={key.enabled ? "green" : "gray"}>
            {key.enabled ? "启用" : "禁用"}
          </StatusBadge>
          <Text
            size="xs"
            c={
              api.expirationState(key.expiresAtUnixSeconds) === "expired"
                ? "red"
                : api.expirationState(key.expiresAtUnixSeconds) === "soon"
                  ? "orange"
                  : "dimmed"
            }
          >
            {api.expirationLabel(key.expiresAtUnixSeconds)}
          </Text>
          {key.expiresAtUnixSeconds != null && (
            <Text size="xs" title={timeTitle(key.expiresAtUnixSeconds)}>
              {new Date(key.expiresAtUnixSeconds * 1000)
                .toISOString()
                .slice(0, 10)}{" "}
              UTC 00:00
            </Text>
          )}
        </>
      ),
    },
    {
      id: "col3",
      title: "本地限制",
      render: (key) => (
        <>
          <Text size="sm">{api.formatKeyLimit(key.limits.requests)} / 日</Text>
          <Text size="xs" c="dimmed">
            {api.formatKeyLimit(key.limits.active)} 并发 ·{" "}
            {api.formatKeyLimit(key.limits.unresolved)} 待核对
          </Text>
        </>
      ),
    },
    {
      id: "col4",
      title: "今日 / 最近使用",
      render: (key) => (
        <>
          <Text size="sm">
            {usage.data?.find((item) => item.keyID === key.id)?.admitted ?? "—"}{" "}
            请求 / {api.formatKeyLimit(key.limits.requests)} 上限
          </Text>
          <Text size="xs">
            费用：
            <MoneyText
              value={
                usage.data?.find((item) => item.keyID === key.id)
                  ?.estimatedMicros
              }
            />
          </Text>
          <Text
            size="xs"
            title={timeTitle(
              usage.data?.find((item) => item.keyID === key.id)
                ?.lastUsedAtUnixSeconds,
            )}
          >
            最近：
            {usage.data?.find((item) => item.keyID === key.id)
              ?.lastUsedAtUnixSeconds == null ? (
              "从未使用"
            ) : (
              <TimeText
                value={
                  usage.data?.find((item) => item.keyID === key.id)
                    ?.lastUsedAtUnixSeconds
                }
              />
            )}
          </Text>
        </>
      ),
    },
    {
      id: "col5",
      title: "操作",
      render: (key) => (
        <>
          <Group gap="xs">
            <ActionIcon
              size="md"
              variant="default"
              aria-label="用量"
              component={Link}
              to={`/usage?key=${encodeURIComponent(key.id)}`}
            >
              <IconChartBar size={17} />
            </ActionIcon>
            <ActionIcon
              size="md"
              variant="default"
              aria-label="编辑"
              disabled={state.disabled}
              onClick={() => state.setEditing(key)}
            >
              <IconPencil size={17} />
            </ActionIcon>
            <Menu position="bottom-end">
              <Menu.Target>
                <ActionIcon
                  size="md"
                  variant="subtle"
                  disabled={state.disabled}
                  aria-label={`${key.principal} 更多操作`}
                >
                  <IconDots size={17} />
                </ActionIcon>
              </Menu.Target>
              <Menu.Dropdown>
                <Menu.Item
                  leftSection={<IconClock size={16} />}
                  onClick={() => setExpiring(key)}
                >
                  设置到期时间
                </Menu.Item>
                <Menu.Item
                  leftSection={<IconRefresh size={16} />}
                  onClick={() => state.setRotating(key)}
                >
                  轮换
                </Menu.Item>
                <Menu.Item
                  color={key.enabled ? "red" : undefined}
                  leftSection={
                    key.enabled ? (
                      <IconBan size={16} />
                    ) : (
                      <IconCheck size={16} />
                    )
                  }
                  onClick={() =>
                    key.enabled ? setDisabling(key) : void toggle(key)
                  }
                >
                  {key.enabled ? "禁用" : "启用"}
                </Menu.Item>
              </Menu.Dropdown>
            </Menu>
          </Group>
        </>
      ),
    },
  ];
  return (
    <DataTable
      rows={keys}
      columns={columns}
      rowKey={(key) => key.id}
      retry={state.reload}
      empty={state.keys.length ? "没有匹配的密钥。" : "尚未创建密钥。"}
    />
  );
}
