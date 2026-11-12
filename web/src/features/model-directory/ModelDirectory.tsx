import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Alert,
  Badge,
  Button,
  Group,
  Modal,
  NumberInput,
  Paper,
  Select,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { Link } from "react-router";
import { z } from "../../shared/schema";
import { ManagementError, request } from "../../shared/management";
import { useManagementSession } from "../../shared/session";
import { usePrivacyMask } from "../../shared/privacy-mask";
import { PageHeader } from "../../shared/ui/PageHeader";
import { ErrorState, LoadingState } from "../../shared/ui/States";
import { localTime } from "../../shared/presentation";
import { fetchAccounts } from "../account-management/api";
import styles from "./ModelDirectory.module.css";

const model = z.object({
  id: z.string().min(1).max(128),
  state: z.enum(["enabled", "retired", "candidate", "incomplete"]),
  reasoningEfforts: z.array(z.string().max(32)).max(8),
  defaultReasoningEffort: z.string().max(32).nullable(),
});
const directory = z.object({
  revision: z.number().int().nonnegative(),
  active: z.array(model).max(32),
  retired: z.array(model).max(32),
  candidates: z.array(model).max(128),
  imageModels: z.array(z.string().max(128)).max(16),
  account: z.string().nullable(),
  fetchedAt: z.number().nullable(),
});
type Model = z.infer<typeof model>;
type Directory = z.infer<typeof directory>;
function parse(value: unknown): Directory {
  const parsed = directory.safeParse(value);
  if (!parsed.success) throw new ManagementError(0, "invalid_response");
  return parsed.data;
}

const states = {
  enabled: { label: "已启用", action: "停用", color: "green" },
  retired: { label: "已停用", action: "重新启用", color: "gray" },
  candidate: { label: "可启用", action: "审核并启用", color: "blue" },
  incomplete: { label: "资料不完整", action: "查看缺项", color: "yellow" },
};

export function ModelDirectory() {
  const owner = useManagementSession();
  const masked = usePrivacyMask();
  const [account, setAccount] = useState<string | null>(null);
  const [selected, setSelected] = useState<Model | null>(null);
  const [input, setInput] = useState<number | string>("");
  const [output, setOutput] = useState<number | string>("");
  const [working, setWorking] = useState<"refresh" | "save" | null>(null);
  const [notice, setNotice] = useState("");
  const [failure, setFailure] = useState("");
  const query = useQuery({
    queryKey: ["model-directory"],
    queryFn: async ({ signal }) =>
      parse(await request("/api/models", { signal })),
    enabled: !!owner.session,
  });
  const accounts = useQuery({
    queryKey: ["model-directory-accounts"],
    queryFn: ({ signal }) => fetchAccounts(signal),
    enabled: !!owner.session && !!query.data,
  });
  const data = query.data;
  const activeAccounts = (accounts.data ?? []).filter(
    (item) => item.mode === "enabled" && item.authorization === "ready",
  );
  const labels = activeAccounts.map((item, index) => ({
    value: item.id,
    label: masked ? `账号 ${index + 1}` : item.displayName || item.id,
  }));
  const chosen = account ?? labels[0]?.value ?? null;
  const observed = labels.find((item) => item.value === data?.account)?.label;

  async function refresh() {
    if (!chosen || !owner.session || working) return;
    setWorking("refresh");
    setFailure("");
    setNotice("");
    try {
      parse(
        await request(
          "/api/accounts/" + encodeURIComponent(chosen) + "/model-candidates",
          {
            method: "POST",
            csrf: owner.session.csrf,
          },
        ),
      );
      await query.refetch({ throwOnError: true });
      setNotice("候选模型已刷新。");
    } catch {
      setFailure("刷新失败。可继续查看上次获取的候选。");
    } finally {
      setWorking(null);
    }
  }

  async function apply() {
    if (!selected || !data || !owner.session || working) return;
    const newModel = selected.state === "candidate";
    if (newModel && (typeof input !== "number" || typeof output !== "number"))
      return;
    setWorking("save");
    setFailure("");
    setNotice("");
    try {
      parse(
        await request("/api/models", {
          method: "PUT",
          csrf: owner.session.csrf,
          body: {
            revision: data.revision,
            model: selected.id,
            enabled: selected.state !== "enabled",
            ...(newModel
              ? { inputMicrosPerMillion: input, outputMicrosPerMillion: output }
              : {}),
          },
        }),
      );
      setSelected(null);
      await query.refetch({ throwOnError: true });
      setNotice(
        selected.state === "enabled"
          ? "模型已停用。"
          : "模型已启用，可在 Key 权限中选择。",
      );
    } catch (error) {
      setSelected(null);
      setFailure(
        error instanceof ManagementError && error.status === 409
          ? "模型目录或账号已变化。请刷新账号候选并核对后重试。"
          : "无法确认保存结果。请核对最新目录。",
      );
      await query.refetch();
    } finally {
      setWorking(null);
    }
  }

  function row(item: Model) {
    const state = states[item.state];
    return (
      <Group
        key={item.id}
        px="md"
        py="sm"
        justify="space-between"
        gap="xs"
        className={styles.row}
      >
        <Stack gap={4}>
          <Text size="sm" fw={650} className={styles.modelID}>
            {item.id}
          </Text>
          {item.defaultReasoningEffort && (
            <Text size="xs" c="dimmed">
              默认 {item.defaultReasoningEffort}
            </Text>
          )}
          <Group gap={5}>
            {item.reasoningEfforts.map((effort) => (
              <Badge key={effort} size="sm" color="gray" variant="light">
                {effort}
              </Badge>
            ))}
          </Group>
        </Stack>
        <Group gap="xs">
          <Badge color={state.color} variant="light">
            {state.label}
          </Badge>
          <Button
            variant="subtle"
            size="compact-sm"
            disabled={working !== null}
            onClick={() => {
              setSelected(item);
              setInput("");
              setOutput("");
            }}
          >
            {state.action}
          </Button>
        </Group>
      </Group>
    );
  }

  if (!owner.session) return null;
  const unavailable =
    query.error instanceof ManagementError && query.error.status === 404;
  return (
    <>
      <PageHeader
        title="模型目录"
        description="管理可以分配给 Key 的模型。"
        actions={
          <Button component={Link} to="/keys" variant="default">
            访问密钥
          </Button>
        }
      />
      {!data &&
        (unavailable ? (
          <Alert>模型目录管理适用于订阅账号池。</Alert>
        ) : query.isError ? (
          <ErrorState retry={() => void query.refetch()}>
            无法读取模型目录。
          </ErrorState>
        ) : (
          <LoadingState />
        ))}
      {data && (
        <Stack>
          {failure && (
            <Alert color="red" role="alert">
              {failure}
            </Alert>
          )}
          {notice && (
            <Alert color="blue" role="status">
              {notice}
            </Alert>
          )}
          <Paper withBorder>
            <Group p="md" justify="space-between" align="flex-start">
              <Stack gap={4}>
                <Title order={2} size="h4">
                  账号发现
                </Title>
                <Text c="dimmed" size="sm">
                  {data.fetchedAt
                    ? [observed, localTime(data.fetchedAt)]
                        .filter(Boolean)
                        .join(" · ")
                    : "刷新账号可见的模型候选"}
                </Text>
              </Stack>
              <Group gap="xs">
                <Select
                  aria-label="发现账号"
                  placeholder="没有可选账号"
                  data={labels}
                  value={chosen}
                  onChange={setAccount}
                  disabled={working !== null || !labels.length}
                />
                <Button
                  loading={working === "refresh"}
                  disabled={!chosen || working === "save"}
                  onClick={() => void refresh()}
                >
                  刷新候选
                </Button>
              </Group>
            </Group>
            {accounts.isError && (
              <Text px="md" pb="md" c="red">
                无法读取订阅账号。
              </Text>
            )}
            {data.candidates.length ? (
              data.candidates.map(row)
            ) : (
              <Text size="sm" c="dimmed" px="md" pb="md">
                {data.fetchedAt
                  ? "没有新增候选。"
                  : "选择账号并刷新后，可审核新增模型。"}
              </Text>
            )}
          </Paper>
          <Paper withBorder>
            <Stack p="md" gap={4}>
              <Title order={2} size="h4">
                网关模型
              </Title>
              <Text c="dimmed" size="sm">
                对话 {data.active.length} 个已启用 · 图片{" "}
                {data.imageModels.length} 个已启用
              </Text>
            </Stack>
            {[...data.active, ...data.retired].map(row)}
            {data.imageModels.map((id) => (
              <Group
                key={id}
                px="md"
                py="sm"
                justify="space-between"
                className={styles.row}
              >
                <Stack gap={4}>
                  <Text size="sm" fw={650}>
                    {id}
                  </Text>
                  <Text c="dimmed" size="xs">
                    图片生成与参考图编辑
                  </Text>
                </Stack>
                <Badge color="green" variant="light">
                  已启用
                </Badge>
              </Group>
            ))}
          </Paper>
        </Stack>
      )}
      <Modal
        opened={selected !== null}
        onClose={() => !working && setSelected(null)}
        title={
          selected?.state === "incomplete"
            ? "待补齐模型资料"
            : selected?.state === "enabled"
              ? "停用模型"
              : "启用模型"
        }
      >
        {selected && (
          <Stack>
            <Text fw={650}>{selected.id}</Text>
            <Group gap={5}>
              {selected.reasoningEfforts.map((effort) => (
                <Badge key={effort} color="gray">
                  {effort}
                </Badge>
              ))}
            </Group>
            <Alert color="yellow">
              {selected.state === "incomplete"
                ? "缺少完整 Codex profile。补齐并审核后可启用。"
                : selected.state === "enabled"
                  ? "停用后，使用该模型的新请求会被拒绝。"
                  : "启用后，选择「全部模型」的 Key 会自动获得此模型。"}
            </Alert>
            {selected.state === "candidate" && (
              <Stack gap="xs">
                <Text size="sm" c="dimmed">
                  填写每百万 Token 的估算费率，单位为微美元。暂不估算时填 0。
                </Text>
                <NumberInput
                  label="输入费率"
                  min={0}
                  max={500_000_000}
                  allowDecimal={false}
                  value={input}
                  onChange={setInput}
                />
                <NumberInput
                  label="输出费率"
                  min={0}
                  max={500_000_000}
                  allowDecimal={false}
                  value={output}
                  onChange={setOutput}
                />
              </Stack>
            )}
            <Group justify="flex-end">
              <Button
                variant="default"
                disabled={working !== null}
                onClick={() => setSelected(null)}
              >
                {selected.state === "incomplete" ? "关闭" : "取消"}
              </Button>
              {selected.state !== "incomplete" && (
                <Button
                  loading={working === "save"}
                  onClick={() => void apply()}
                  disabled={
                    selected.state === "candidate" &&
                    (typeof input !== "number" || typeof output !== "number")
                  }
                >
                  {selected.state === "enabled" ? "确认停用" : "确认启用"}
                </Button>
              )}
            </Group>
          </Stack>
        )}
      </Modal>
    </>
  );
}
