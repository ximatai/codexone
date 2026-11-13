import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Alert,
  Badge,
  Button,
  Checkbox,
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
  visionInput: z.boolean().optional(),
  previousVisionInput: z.boolean().nullable().optional(),
  defaultReasoningEffort: z.string().max(32).nullable(),
  supportedReasoningEfforts: z.array(z.string().max(32)).max(8).optional(),
  profileDefaultReasoningEffort: z.string().max(32).nullable().optional(),
  configuredReasoningEfforts: z.array(z.string()).max(8).nullish(),
  configuredDefaultReasoningEffort: z.string().max(32).nullable().optional(),
  resetReasoningRequired: z.boolean().optional(),
});
const directory = z.object({
  revision: z.number().int().nonnegative(),
  active: z.array(model).max(32),
  retired: z.array(model).max(32),
  candidates: z.array(model).max(128),
  imageModels: z.array(z.string().max(128)).max(16),
  account: z.string().nullable(),
  candidateRevision: z.string().uuid().nullable().optional(),
  fetchedAt: z.number().nullable(),
});
type Model = z.infer<typeof model>;
type Directory = z.infer<typeof directory>;
function parse(value: unknown): Directory {
  const parsed = directory.safeParse(value);
  if (!parsed.success) throw new ManagementError(0, "invalid_response");
  return parsed.data;
}

// Standard input/output rates in USD per million tokens.
const referenceRates = new Map<string, readonly [number, number]>([
  ["gpt-5.6-luna", [0.2, 1.2]],
  ["gpt-5.6-terra", [2, 12]],
  ["gpt-6-luna", [0.1, 0.5]],
  ["gpt-6-sol", [2, 10]],
  ["gpt-6.1-sol", [2, 10]],
  ["gpt-6.1-terra", [1, 5]],
]);

const maximumRateUSD = 500;

function rateInMicros(value: number | string) {
  if (typeof value === "string" && !/^\d+(\.\d{0,6})?$/.test(value))
    return null;
  const rate = Number(value);
  return rate >= 0 && rate <= maximumRateUSD
    ? Math.round(rate * 1_000_000)
    : null;
}

type ReasoningDraft = { allowed: string[]; preferred: string | null };

function supportedEfforts(model: Model) {
  return model.supportedReasoningEfforts ?? model.reasoningEfforts;
}

function reasoningBody(model: Model, value: ReasoningDraft) {
  const savedRange = model.configuredReasoningEfforts;
  const keepsSavedRange =
    savedRange?.length === value.allowed.length &&
    savedRange.every((effort) => value.allowed.includes(effort));
  return {
    allowedReasoningEfforts:
      !keepsSavedRange &&
      value.allowed.length === supportedEfforts(model).length
        ? null
        : value.allowed,
    defaultReasoningEffort: value.preferred,
  };
}

function ReasoningFields({
  model,
  value,
  onChange,
  disabled,
}: {
  model: Model;
  value: ReasoningDraft;
  onChange: (draft: ReasoningDraft) => void;
  disabled: boolean;
}) {
  const efforts = supportedEfforts(model);
  const narrowed = reasoningBody(model, value).allowedReasoningEfforts !== null;
  const profileDefault = model.profileDefaultReasoningEffort;
  const autoEffort =
    profileDefault && value.allowed.includes(profileDefault)
      ? profileDefault
      : narrowed
        ? efforts.find((effort) => value.allowed.includes(effort))
        : undefined;
  return (
    <>
      <Checkbox.Group
        label="可选档位"
        value={value.allowed}
        onChange={(allowed) =>
          onChange({
            ...value,
            allowed,
            preferred:
              value.preferred && allowed.includes(value.preferred)
                ? value.preferred
                : null,
          })
        }
      >
        <Group gap="sm" mt={6}>
          {efforts.map((effort) => (
            <Checkbox
              key={effort}
              value={effort}
              label={effort}
              disabled={disabled}
            />
          ))}
        </Group>
      </Checkbox.Group>
      <Select
        label="默认档位"
        value={value.preferred ?? ""}
        data={[
          {
            value: "",
            label: autoEffort ? `自动 · ${autoEffort}` : "跟随模型",
          },
          ...efforts.filter((effort) => value.allowed.includes(effort)),
        ]}
        allowDeselect={false}
        disabled={disabled || !value.allowed.length}
        onChange={(effort) => onChange({ ...value, preferred: effort || null })}
      />
      <Text size="sm" c="dimmed">
        此设置适用于使用此模型的所有 Key。Key 自身的限制仍会生效。
      </Text>
      {narrowed && value.allowed.length > 0 && (
        <Alert color="yellow">
          收窄范围后，请求必须显式指定获准档位。若某个 Key
          没有任何获准档位，客户端目录将不再显示此模型。
        </Alert>
      )}
    </>
  );
}

const states = {
  enabled: { label: "已启用", action: "停用", color: "green" },
  retired: { label: "已停用", action: "重新启用", color: "gray" },
  candidate: { label: "可启用", action: "审核并启用", color: "blue" },
  incomplete: { label: "资料不完整", action: "查看缺项", color: "yellow" },
};

export function ModelDirectory() {
  const owner = useManagementSession();
  const queryClient = useQueryClient();
  const masked = usePrivacyMask();
  const [account, setAccount] = useState<string | null>(null);
  const [selected, setSelected] = useState<Model | null>(null);
  const [reasoning, setReasoning] = useState<
    (ReasoningDraft & { model: Model; revision: number }) | null
  >(null);
  const [activationReasoning, setActivationReasoning] =
    useState<ReasoningDraft | null>(null);
  const [approvedRevision, setApprovedRevision] = useState(0);
  const [reasoningError, setReasoningError] = useState("");
  const [resetReasoning, setResetReasoning] = useState(false);
  const [approvedCandidateRevision, setApprovedCandidateRevision] = useState<
    string | null
  >(null);
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
            timeout: 35000,
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

  const inputMicros = rateInMicros(input);
  const outputMicros = rateInMicros(output);
  const ratesValid = inputMicros !== null && outputMicros !== null;

  async function apply() {
    if (!selected || !data || !owner.session || working) return;
    const newModel = selected.state === "candidate";
    if (newModel && !ratesValid) return;
    if (selected.resetReasoningRequired && !resetReasoning) return;
    if (activationReasoning && !activationReasoning.allowed.length) return;
    setWorking("save");
    setFailure("");
    setNotice("");
    try {
      parse(
        await request("/api/models", {
          method: "PUT",
          csrf: owner.session.csrf,
          body: {
            revision: approvedRevision,
            model: selected.id,
            enabled: selected.state !== "enabled",
            ...(activationReasoning
              ? reasoningBody(selected, activationReasoning)
              : {}),
            ...(selected.resetReasoningRequired && resetReasoning
              ? { resetReasoningSettings: true }
              : {}),
            ...(selected.state !== "enabled" && approvedCandidateRevision
              ? { candidateRevision: approvedCandidateRevision }
              : {}),
            ...(newModel
              ? {
                  inputMicrosPerMillion: inputMicros,
                  outputMicrosPerMillion: outputMicros,
                }
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

  async function saveReasoning() {
    if (!reasoning || !owner.session || working || !reasoning.allowed.length)
      return;
    setWorking("save");
    setReasoningError("");
    setNotice("");
    setFailure("");
    try {
      await queryClient.cancelQueries({
        queryKey: ["model-directory"],
        exact: true,
      });
      const next = parse(
        await request("/api/models/reasoning", {
          method: "PUT",
          csrf: owner.session.csrf,
          body: {
            revision: reasoning.revision,
            model: reasoning.model.id,
            ...reasoningBody(reasoning.model, reasoning),
          },
        }),
      );
      queryClient.setQueryData(["model-directory"], next);
      setReasoning(null);
      setNotice("推理设置已保存。");
    } catch (error) {
      setReasoningError(
        error instanceof ManagementError && error.status === 409
          ? "目录已变化，请关闭设置后重新打开。"
          : "无法确认保存结果。请关闭设置后核对最新目录。",
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
          {item.state === "enabled" &&
            (item.supportedReasoningEfforts ?? item.reasoningEfforts).length >
              0 && (
              <Button
                variant="subtle"
                size="compact-sm"
                disabled={working !== null}
                onClick={() => {
                  if (!data) return;
                  setReasoningError("");
                  setReasoning({
                    model: item,
                    revision: data.revision,
                    allowed: item.reasoningEfforts,
                    preferred: item.configuredDefaultReasoningEffort ?? null,
                  });
                }}
              >
                推理设置
              </Button>
            )}
          <Button
            variant="subtle"
            size="compact-sm"
            disabled={working !== null}
            onClick={() => {
              if (!data) return;
              setSelected(item);
              setApprovedRevision(data.revision);
              setActivationReasoning(
                (item.state === "candidate" || item.state === "retired") &&
                  supportedEfforts(item).length > 0
                  ? {
                      allowed: item.reasoningEfforts,
                      preferred: item.configuredDefaultReasoningEffort ?? null,
                    }
                  : null,
              );
              setResetReasoning(false);
              setApprovedCandidateRevision(data?.candidateRevision ?? null);
              const [input, output] = referenceRates.get(item.id) ?? [0, 0];
              setInput(input.toFixed(2));
              setOutput(output.toFixed(2));
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
        opened={reasoning !== null}
        onClose={() => !working && setReasoning(null)}
        title="推理设置"
      >
        {reasoning && (
          <Stack>
            <Text fw={650}>{reasoning.model.id}</Text>
            <ReasoningFields
              model={reasoning.model}
              value={reasoning}
              onChange={(value) => setReasoning({ ...reasoning, ...value })}
              disabled={working !== null}
            />
            {reasoningError && <Alert color="red">{reasoningError}</Alert>}
            <Group justify="flex-end">
              <Button
                variant="default"
                disabled={working !== null}
                onClick={() => setReasoning(null)}
              >
                取消
              </Button>
              <Button
                loading={working === "save"}
                disabled={!reasoning.allowed.length || !!reasoningError}
                onClick={() => void saveReasoning()}
              >
                保存
              </Button>
            </Group>
          </Stack>
        )}
      </Modal>
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
            <Text size="sm">
              视觉输入：{selected.visionInput ? "支持" : "未启用"}
            </Text>
            {selected.state === "retired" &&
              selected.previousVisionInput != null &&
              selected.previousVisionInput !== selected.visionInput && (
                <Alert color="yellow">
                  {selected.visionInput
                    ? "此模型新增视觉输入能力。已选择此模型且获视觉输入权限的 Key 将可以处理图片。"
                    : "此模型不再提供视觉输入，相关 Key 将不能通过此模型处理图片。"}
                </Alert>
              )}
            {selected.state === "candidate" && selected.visionInput && (
              <Text size="sm" c="dimmed">
                已获视觉输入权限且跟随全部模型的 Key 可使用此模型处理图片。
              </Text>
            )}
            {selected.resetReasoningRequired && (
              <Checkbox
                label="新模型资料与原推理设置不兼容，确认按新资料重置档位后启用"
                checked={resetReasoning}
                disabled={working !== null}
                onChange={(event) =>
                  setResetReasoning(event.currentTarget.checked)
                }
              />
            )}
            {activationReasoning && (
              <ReasoningFields
                model={selected}
                value={activationReasoning}
                onChange={setActivationReasoning}
                disabled={working !== null}
              />
            )}
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
                  {referenceRates.has(selected.id)
                    ? "已预填公开参考价，可修改。"
                    : "暂无参考价，预填 0，可修改。"}
                </Text>
                <NumberInput
                  label="输入费率（美元／百万 Token）"
                  min={0}
                  max={maximumRateUSD}
                  allowNegative={false}
                  decimalScale={6}
                  step={0.01}
                  value={input}
                  onChange={setInput}
                />
                <NumberInput
                  label="输出费率（美元／百万 Token）"
                  min={0}
                  max={maximumRateUSD}
                  allowNegative={false}
                  decimalScale={6}
                  step={0.01}
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
                    activationReasoning?.allowed.length === 0 ||
                    (selected.resetReasoningRequired && !resetReasoning) ||
                    (selected.state === "candidate" && !ratesValid)
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
