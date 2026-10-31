import { quotaStale } from "./quota";
import { useEffect, useRef, useState } from "react";
import { ErrorState } from "../../shared/ui/States";
import { Button, Skeleton } from "@mantine/core";
import styles from "./accounts.module.css";
import { ManagementError } from "../../shared/management";
import type { Account } from "./api";
import {
  fetchObservation,
  type AccountObservability as Snapshot,
  type QuotaWindow,
  type QuotaLimit,
} from "./observation-api";
import { timeTitle } from "../../shared/presentation";
import { QuotaWindowBar } from "./QuotaWindowBar";
export const utc = timeTitle;
function duration(value: number | null): string {
  if (value === null) return "时长未提供";
  if (value % 86400 === 0) return `${value / 86400} 天`;
  if (value % 3600 === 0) return `${value / 3600} 小时`;
  return `${value} 秒`;
}
function Window({
  title,
  value,
}: {
  title: string;
  value: QuotaWindow | null;
}) {
  return (
    <div className={styles.window}>
      {!value ? (
        <p className={styles.subtle}>
          {title} · <span>上游未提供</span>
        </p>
      ) : (
        <>
          <span className={styles.subtle}>
            {duration(value.durationSeconds)}
          </span>

          <QuotaWindowBar title={title} value={value} />
        </>
      )}
    </div>
  );
}
function LimitStatus({ value }: { value: QuotaLimit | undefined }) {
  const flag = (value: boolean | null | undefined) =>
    value === undefined || value === null ? "未提供" : value ? "是" : "否";
  return (
    <p
      className={
        value?.allowed === false || value?.limitReached === true
          ? styles.warning
          : styles.subtle
      }
    >
      上游允许使用：{flag(value?.allowed)} · 已达窗口限额：
      {flag(value?.limitReached)}
    </p>
  );
}
function state(value: Snapshot, now: number) {
  if (value.quota.state === "unavailable") return "额度不可用";
  if (quotaStale(value, now)) return "额度观测已陈旧";
  return "";
}
export function AccountObservability({
  account,
  now,
  disabled,
  onObserve,
  onUnauthorized,
  inDetails = false,
}: {
  inDetails?: boolean;
  account: Account;
  now: number;
  disabled: boolean;
  onObserve: () => void;
  onUnauthorized: () => void;
}) {
  const unauthorized = useRef(onUnauthorized);
  unauthorized.current = onUnauthorized;
  const [expanded, setExpanded] = useState(inDetails);
  const [details, setDetails] = useState<Snapshot | null>(null);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    if (!expanded) {
      setDetails(null);
      return;
    }
    const abort = new AbortController();
    setDetails(null);
    setFailed(false);
    void fetchObservation(account.id, abort.signal)
      .then((value) => {
        if (!abort.signal.aborted) setDetails(value);
      })
      .catch((cause) => {
        if (abort.signal.aborted) return;
        if (cause instanceof ManagementError && cause.status === 401) {
          setDetails(null);
          unauthorized.current();
        } else setFailed(true);
      });
    return () => abort.abort();
  }, [expanded, account.id, account.revision, account.observability, retry]);
  const value = details ?? account.observability;
  const base = value?.quota.limits.find((limit) => limit.id === "codex");
  const health = value?.health;
  const current = Math.max(now, performance.now());
  return (
    <div className={styles.observation}>
      <span
        className={
          health?.authenticationRejected || health?.cooldownCount
            ? styles.attention
            : styles.subtle
        }
      >
        {health?.authenticationRejected
          ? "派发认证被拒绝，请刷新授权"
          : health?.cooldownCount
            ? `最近读取：${health.cooldownCount} 个模型冷却`
            : value
              ? "执行健康：无已知阻断"
              : "健康尚无观测"}
      </span>
      <small>
        {value ? state(value, current) : "额度尚无观测"}
        {value?.quota.failure ? " · 最近读取失败" : ""}
      </small>

      {(base?.allowed === false || base?.limitReached === true) && (
        <small className={styles.attention}>
          上游额度报告受限，请查看窗口详情
        </small>
      )}
      {!inDetails && (
        <Button
          variant="subtle"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? "收起额度与健康" : "额度与健康详情"}
        </Button>
      )}
      {expanded && (
        <div
          className={styles.details}
          role="region"
          aria-label={`${account.id} 额度与健康`}
        >
          <Button
            variant="default"
            disabled={
              disabled ||
              failed ||
              !details ||
              !value?.observing ||
              account.authorization !== "ready"
            }
            onClick={onObserve}
          >
            读取上游额度
          </Button>
          {!details && !failed ? (
            <Skeleton
              height={80}
              role="status"
              aria-label="正在读取观测详情…"
            />
          ) : failed ? (
            <ErrorState retry={() => setRetry(retry + 1)} retryLabel="重试详情">
              详情读取失败。
            </ErrorState>
          ) : (
            details && (
              <>
                <details>
                  <summary>窗口口径</summary>
                  <p className={styles.subtle}>
                    订阅账号的上游窗口；与本地 Key 限额、估算费用相互独立。
                  </p>
                </details>
                <LimitStatus value={base} />
                <div className={styles.windows}>
                  <Window title="主窗口" value={base?.primary ?? null} />
                  <Window title="次窗口" value={base?.secondary ?? null} />
                </div>
                <small>
                  最近成功：{utc(details.quota.observedAtUnixSeconds)}
                </small>
                <small>
                  最近尝试：{utc(details.quota.attemptedAtUnixSeconds)}
                </small>
                {details.quota.failure && (
                  <p className={styles.warning}>
                    最近一次读取失败，保留上次成功值。
                    {details.quota.failure === "refresh_required"
                      ? "请先刷新授权。"
                      : "失败不表示余额为零。"}
                  </p>
                )}
                {details.quota.limits
                  .filter((limit) => limit.id !== "codex")
                  .map((limit) => (
                    <div key={limit.id} className={styles.additional}>
                      <strong>其他上游窗口 · {limit.id}</strong>
                      <LimitStatus value={limit} />
                      <div className={styles.windows}>
                        <Window title="主窗口" value={limit.primary} />
                        <Window title="次窗口" value={limit.secondary} />
                      </div>
                    </div>
                  ))}
                {details.health.lastFailure && (
                  <small>
                    最近上游异常：
                    {details.health.lastFailure === "authentication_rejected"
                      ? "认证拒绝"
                      : details.health.lastFailure === "rate_limited"
                        ? "限流"
                        : "暂不可用"}{" "}
                    · {utc(details.health.lastFailureAtUnixSeconds)}
                  </small>
                )}
                {details.health.authenticationRejected && (
                  <p className={styles.warning}>
                    当前凭证的实际派发曾被拒绝。新执行已暂停，请刷新授权或重新授权；已有未知执行仍保留。
                  </p>
                )}
                {(details.health.cooldowns ?? []).map((item) => (
                  <p key={item.model} className={styles.warning}>
                    {item.model}：
                    {item.failure === "rate_limited"
                      ? "上游限流"
                      : "上游暂不可用"}
                    ，冷却至 {utc(item.untilUnixSeconds)}。
                  </p>
                ))}
              </>
            )
          )}
          {!value?.observing && (
            <small>额度观察服务未就绪，请稍后重新读取账号。</small>
          )}
        </div>
      )}
    </div>
  );
}
