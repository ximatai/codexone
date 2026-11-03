import { useEffect, useRef, useState } from "react";
import {
  Alert,
  Badge,
  Button,
  Group,
  NumberInput,
  NativeSelect,
  Paper,
  Stack,
  Switch,
  Text,
  Title,
} from "@mantine/core";
import { ConfirmModal } from "../../shared/ui/ConfirmModal";
import { ManagementError } from "../../shared/management";
import { accountName } from "../../shared/account-presentation";
import type { Account } from "./api";
import type { useAccounts } from "./useAccounts";
import * as api from "./reset-credits-api";

type Selection =
  { kind: "credit"; credit: api.ResetCredit } | { kind: "reconcile" };
const expiry = (value: string | null) =>
  value ? new Date(value).toLocaleString() : "上游未提供到期时间";
export function ResetCredits({
  account,
  disabled,
  reloadToken,
  mutation,
  onUnauthorized,
  hideTitle = false,
}: {
  hideTitle?: boolean;
  account: Account;
  disabled: boolean;
  reloadToken: unknown;
  mutation: ReturnType<typeof useAccounts>["mutation"];
  onUnauthorized: () => void;
}) {
  const [state, setState] = useState<api.ResetCreditState | null>(null);
  const [list, setList] = useState<api.ResetCreditList | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [version, setVersion] = useState(0);
  const [selection, setSelection] = useState<Selection | null>(null);
  const [auto, setAuto] = useState(false);
  const [minutes, setMinutes] = useState<string | number>(1440);
  const [unit, setUnit] = useState<"minutes" | "hours">("hours");
  const [retries, setRetries] = useState<string | number>(3);
  const unauthorized = useRef(onUnauthorized);
  unauthorized.current = onUnauthorized;
  useEffect(() => {
    const abort = new AbortController();
    setLoading(true);
    setError("");
    async function load() {
      try {
        const saved = await api.fetchResetCreditState(account.id, abort.signal);
        if (abort.signal.aborted) return;
        setState(saved);
        setAuto(saved.settings.autoUseBeforeExpiry);
        setMinutes(saved.settings.leadMinutes);
        setUnit(saved.settings.leadMinutes % 60 === 0 ? "hours" : "minutes");
        setRetries(saved.settings.retryCount);
        const live = await api.fetchResetCredits(account.id, abort.signal);
        if (!abort.signal.aborted) {
          setList(live);
          setState(live.state);
          setAuto(live.state.settings.autoUseBeforeExpiry);
          setMinutes(live.state.settings.leadMinutes);
          setUnit(
            live.state.settings.leadMinutes % 60 === 0 ? "hours" : "minutes",
          );
          setRetries(live.state.settings.retryCount);
        }
      } catch (cause) {
        if (abort.signal.aborted) return;
        if (cause instanceof ManagementError && cause.status === 401)
          unauthorized.current();
        else
          setError(
            "重置卡读取失败。保留的列表可能已变化，请重新读取后再选择。",
          );
      } finally {
        if (!abort.signal.aborted) setLoading(false);
      }
    }
    void load();
    return () => abort.abort();
  }, [account.id, account.revision, reloadToken, version]);
  const blocked =
    disabled || loading || !state || account.authorization !== "ready";
  const selectable = !blocked && !error && !state?.pending;
  const leadMinutes = Math.round(Number(minutes));
  const validSettings =
    typeof minutes === "number" &&
    Math.abs(minutes - leadMinutes) < 0.000001 &&
    typeof retries === "number" &&
    Number.isInteger(retries) &&
    Number(minutes) >= 0 &&
    Number(minutes) <= 1440 &&
    Number(retries) >= 0 &&
    Number(retries) <= 5 &&
    leadMinutes >= 1 &&
    leadMinutes <= 1440 &&
    leadMinutes >= Number(retries) + 1;
  async function consume() {
    if (!selection) return;
    const creditID =
      selection.kind === "credit" ? selection.credit.id : undefined;
    setSelection(null);
    await mutation(
      (csrf, signal) =>
        api.consumeResetCredit(account.id, creditID, csrf, signal),
      (code) => ({
        text: api.resetCreditMessage(code),
        warning: code !== "reset" && code !== "already_redeemed",
      }),
    );
    setVersion((v) => v + 1);
  }
  return (
    <section aria-label="重置卡">
      <Stack gap="sm">
        <Group justify={hideTitle ? "flex-end" : "space-between"}>
          {!hideTitle && (
            <Title order={3} size="h5">
              重置卡
            </Title>
          )}
          <Button
            variant="subtle"
            disabled={loading || disabled}
            onClick={() => setVersion((v) => v + 1)}
            aria-label="重新读取重置卡"
          >
            刷新
          </Button>
        </Group>
        {loading && <Text role="status">正在读取重置卡…</Text>}
        {error && (
          <Alert color="yellow" role="alert">
            {error}
          </Alert>
        )}
        {state?.lastCode && (
          <Alert color={state.pending ? "yellow" : "blue"} role="status">
            最近操作：{api.resetCreditMessage(state.lastCode)}
          </Alert>
        )}
        {state?.pending && (
          <Button
            disabled={blocked}
            onClick={() => setSelection({ kind: "reconcile" })}
          >
            核对上次操作
          </Button>
        )}
        {list && (
          <>
            <Text size="sm">
              上次读取可用 {list.availableCount} 张 · {list.credits.length}{" "}
              张记录
            </Text>
            {!list.credits.length && (
              <Text size="sm" c="dimmed">
                暂无重置卡
              </Text>
            )}
            {list.credits.map((credit) => (
              <Paper key={credit.id} withBorder p="sm">
                <Stack gap="xs">
                  <Group justify="space-between">
                    <Text fw={600} className="wrap-anywhere">
                      {credit.title || "未命名重置卡"}
                    </Text>
                    <Badge
                      color={credit.status === "available" ? "blue" : "gray"}
                    >
                      {credit.status === "available"
                        ? "可用"
                        : credit.status === "used"
                          ? "已使用"
                          : credit.status === "expired"
                            ? "已过期"
                            : "其他状态"}
                    </Badge>
                  </Group>
                  {credit.description && (
                    <Text size="sm" className="wrap-anywhere">
                      {credit.description}
                    </Text>
                  )}
                  <details>
                    <summary>详情</summary>{" "}
                    <Text size="xs" className="wrap-anywhere">
                      标识：{credit.id} · 类型：{credit.type} · 状态：
                      {credit.status}
                    </Text>
                    <Text size="xs">发放：{expiry(credit.grantedAt)}</Text>
                  </details>
                  <Text size="sm">到期：{expiry(credit.expiresAt)}</Text>
                  <Button
                    variant="light"
                    disabled={
                      !selectable ||
                      credit.status !== "available" ||
                      (!!credit.expiresAt &&
                        Date.parse(credit.expiresAt) <= Date.now())
                    }
                    onClick={() => setSelection({ kind: "credit", credit })}
                  >
                    使用{credit.title || "此重置卡"}
                  </Button>
                </Stack>
              </Paper>
            ))}
          </>
        )}
        <Switch
          aria-label="到期前自动使用"
          label="到期前自动使用"
          title="仅对启用且授权正常的账号生效；每轮一张最早到期卡，无到期时间的卡不自动使用。"
          checked={auto}
          disabled={disabled || loading || !state}
          onChange={(event) => setAuto(event.currentTarget.checked)}
        />
        <NumberInput
          aria-label="提前量"
          label="提前量"
          title={`1–1440 分钟（最多 24 小时）；当前 ${minutes} 分钟`}
          value={
            typeof minutes === "number" && unit === "hours"
              ? Number((minutes / 60).toFixed(8))
              : minutes
          }
          min={0}
          max={unit === "hours" ? 24 : 1440}
          step={1}
          hideControls
          rightSectionWidth={90}
          rightSection={
            <NativeSelect
              w={90}
              styles={{ input: { paddingLeft: 10, paddingRight: 24 } }}
              aria-label="提前量单位"
              value={unit}
              onChange={(event) =>
                setUnit(event.currentTarget.value as "minutes" | "hours")
              }
              data={[
                { value: "minutes", label: "分钟" },
                { value: "hours", label: "小时" },
              ]}
              variant="unstyled"
              disabled={disabled || loading || !state}
            />
          }
          disabled={disabled || loading || !state}
          onChange={(value) =>
            setMinutes(
              typeof value === "number"
                ? value * (unit === "hours" ? 60 : 1)
                : value,
            )
          }
        />
        <NumberInput
          aria-label="失败后重试次数"
          label="失败后重试次数"
          description="每隔1分钟重试，到期即止；手动使用不自动重试。"
          value={retries}
          min={0}
          max={5}
          allowDecimal={false}
          disabled={disabled || loading || !state}
          onChange={setRetries}
        />
        {validSettings ? (
          <Text size="sm" role="status" className="visually-hidden">
            到期前 {Number(minutes)} 分钟自动使用；失败后最多重试{" "}
            {Number(retries)} 次。
          </Text>
        ) : (
          <Text size="sm" c="red" role="alert">
            提前量须为整数分钟：范围为 1–1440 分钟（最多 24
            小时），且至少为重试次数加 1 分钟，以便重试在到期前完成。
          </Text>
        )}
        <Button
          disabled={
            disabled ||
            loading ||
            !state ||
            !validSettings ||
            (auto === state.settings.autoUseBeforeExpiry &&
              leadMinutes === state.settings.leadMinutes &&
              retries === state.settings.retryCount)
          }
          onClick={async () => {
            if (!state || !validSettings) return;
            await mutation(
              (csrf, signal) =>
                api.saveResetCreditSettings(
                  account.id,
                  state.revision,
                  {
                    autoUseBeforeExpiry: auto,
                    leadMinutes,
                    retryCount: Number(retries),
                  },
                  csrf,
                  signal,
                ),
              "重置卡自动使用设置已保存。",
            );
            setVersion((v) => v + 1);
          }}
          aria-label="保存重置卡设置"
        >
          保存
        </Button>
        <ConfirmModal
          zIndex={400}
          opened={!!selection}
          title={
            selection?.kind === "reconcile"
              ? "确认核对上次操作"
              : "确认使用重置卡"
          }
          busy={disabled}
          disabled={blocked}
          close={() => setSelection(null)}
          confirm={() => void consume()}
          label={selection?.kind === "reconcile" ? "确认核对" : "确认使用"}
        >
          <Stack>
            <Text>{accountName(account.id, [], account.displayName)}</Text>
            {selection?.kind === "credit" ? (
              <>
                <Text>{selection.credit.title || "未命名重置卡"}</Text>
                <Text>到期：{expiry(selection.credit.expiresAt)}</Text>
              </>
            ) : (
              <Text>沿用已保存的请求编号核对原操作，不会另选一张卡。</Text>
            )}
            <Text size="sm">
              重置成功会消耗一张卡。当前没有可重置的用量时，卡不会消耗。
            </Text>
          </Stack>
        </ConfirmModal>
      </Stack>
    </section>
  );
}
