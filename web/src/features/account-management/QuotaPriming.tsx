import { useEffect, useRef, useState } from "react";
import {
  Alert,
  Button,
  NativeSelect,
  Stack,
  Switch,
  Text,
  Textarea,
  Title,
} from "@mantine/core";
import { ManagementError } from "../../shared/management";
import type { Account } from "./api";
import type { useAccounts } from "./useAccounts";
import * as api from "./quota-priming-api";
export function QuotaPriming({
  account,
  disabled,
  reloadToken,
  mutation,
  onUnauthorized,
}: {
  account: Account;
  disabled: boolean;
  reloadToken: unknown;
  mutation: ReturnType<typeof useAccounts>["mutation"];
  onUnauthorized: () => void;
}) {
  const [state, setState] = useState<api.PrimingState | null>(null);
  const [enabled, setEnabled] = useState(false);
  const [model, setModel] = useState("");
  const [message, setMessage] = useState("hello");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [version, setVersion] = useState(0);
  const unauthorized = useRef(onUnauthorized);
  unauthorized.current = onUnauthorized;
  useEffect(() => {
    const abort = new AbortController();
    setLoading(true);
    setError(false);
    setState(null);
    void api
      .fetchPriming(account.id, abort.signal)
      .then((saved) => {
        if (abort.signal.aborted) return;
        setState(saved);
        setEnabled(saved.settings.enabled);
        setModel(saved.settings.model ?? saved.defaultModel ?? "");
        setMessage(saved.settings.message);
      })
      .catch((cause) => {
        if (abort.signal.aborted) return;
        if (cause instanceof ManagementError && cause.status === 401)
          unauthorized.current();
        else setError(true);
      })
      .finally(() => {
        if (!abort.signal.aborted) setLoading(false);
      });
    return () => abort.abort();
  }, [account.id, account.revision, reloadToken, version]);
  const blocked = disabled || loading || !state;
  const valid =
    api.validPrimingMessage(message) && !!state?.models.includes(model);
  const changed =
    state &&
    (enabled !== state.settings.enabled ||
      model !== (state.settings.model ?? state.defaultModel ?? "") ||
      message !== state.settings.message);
  return (
    <section aria-label="空闲窗口预热">
      <Stack gap="sm">
        <Title order={3} size="h5">
          空闲窗口预热
        </Title>
        <Text size="sm">
          默认关闭。检测到 5
          小时或每周窗口空闲时发送一次合成请求，以便提前开始计时。这会消耗订阅额度，并可能增加提供者风控或账号受限风险。
        </Text>
        {loading && <Text role="status">正在读取预热设置…</Text>}
        {error && (
          <Alert color="yellow" role="alert">
            预热设置读取失败，请重新读取。
          </Alert>
        )}
        <Button
          variant="subtle"
          disabled={disabled || loading}
          onClick={() => setVersion((v) => v + 1)}
        >
          重新读取预热设置
        </Button>
        {state?.attention && (
          <Alert color="yellow">
            {state.attention === "model_removed"
              ? "所选模型已移除，预热已关闭。请选择当前模型后保存。"
              : "预热连续失败，已自动关闭。核对账号后可重新保存启用。"}
          </Alert>
        )}
        <Switch
          label="自动预热空闲窗口"
          checked={enabled}
          disabled={blocked || !state?.models.length}
          onChange={(e) => setEnabled(e.currentTarget.checked)}
        />
        <NativeSelect
          label="预热模型"
          description="仅使用当前配置的对话模型。默认选择本地输入与输出费率之和最低的模型，同价按模型 ID 排序。"
          value={model}
          disabled={blocked || !state?.models.length}
          data={[
            ...(!state?.models.includes(model)
              ? [
                  {
                    value: model,
                    label: model ? `${model}（已移除）` : "没有配置模型",
                  },
                ]
              : []),
            ...(state?.models.map((id) => ({ value: id, label: id })) ?? []),
          ]}
          onChange={(e) => setModel(e.currentTarget.value)}
        />
        <Textarea
          label="预热消息"
          description="1–200 个字符，仅纯文本；推理和输出参数固定为最小档位。"
          value={message}
          disabled={blocked}
          rows={3}
          onChange={(e) => setMessage(e.currentTarget.value)}
          error={
            !api.validPrimingMessage(message)
              ? "请输入 1–200 个纯文本字符，不含换行或控制字符。"
              : undefined
          }
        />
        <Text size="xs" aria-live="polite">
          {[...message].length} / 200 字符
        </Text>
        <Text size="sm">
          最近预热：
          {state?.lastAttemptAt
            ? new Date(state.lastAttemptAt * 1000).toLocaleString()
            : "—"}{" "}
          · {state ? api.primingResult(state.lastResult) : "状态不可用"}
        </Text>
        <Button
          disabled={blocked || !valid || !changed}
          onClick={async () => {
            if (!state || !valid) return;
            await mutation(
              (csrf, signal) =>
                api.savePriming(
                  account.id,
                  state.revision,
                  { enabled, model, message },
                  csrf,
                  signal,
                ),
              "空闲窗口预热设置已保存。",
            );
            setVersion((v) => v + 1);
          }}
        >
          保存预热设置
        </Button>
      </Stack>
    </section>
  );
}
