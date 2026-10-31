import { fetchAccounts } from "../account-management/api";
import { useQuery } from "@tanstack/react-query";
import { ErrorState, LoadingState } from "../../shared/ui/States";
import { UsageDetail } from "./UsageDetail";
import styles from "./usage.module.css";
import { useQueryClient } from "@tanstack/react-query";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type FormEvent,
} from "react";
import { ManagementError } from "../../shared/management";
import * as api from "./api";
import { KeyLimitsSummary } from "../key-management/KeyLimitsSummary";
import {
  Button,
  Checkbox,
  Group,
  NativeSelect,
  Paper,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import {
  failures,
  modes,
  states,
  terms,
  money,
  localTime,
} from "../../shared/presentation";
import { UsageTrend } from "./UsageTrend";
import { UsageRequests } from "./UsageRequests";
import { UsageEvidence, UsageSummary } from "./UsageSummary";
import { utc } from "./format";
export { duration } from "./format";
export { failures } from "../../shared/presentation";
export interface UsageNavigation {
  history: (string | null)[];
  page: number;
  window: api.UsageFilters["window"];
  scroll: number;
}
export function usageNavigationKey(filters: api.UsageFilters, page: number) {
  return `usage:${JSON.stringify(filters)}:page:${page}`;
}
export function UsageOverview({
  selection,
  paused,
  onUnauthorized,
  initialFilters,
  onApplied,
  requestedPage = 0,
  navigationStore,
  restoreView = true,
}: {
  selection: { keyID: string; sequence: number } | null;
  paused: boolean;
  onUnauthorized: () => void;
  initialFilters?: api.UsageFilters;
  onApplied?: (filters: api.UsageFilters, navigation?: UsageNavigation) => void;
  requestedPage?: number;
  navigationStore?: Map<string, unknown>;
  restoreView?: boolean;
}) {
  const queryClient = useQueryClient();
  const accounts = useQuery({
    queryKey: ["accounts", "names"],
    queryFn: ({ signal }) => fetchAccounts(signal),
    staleTime: 15000,
  });
  useEffect(() => {
    if (
      accounts.error instanceof ManagementError &&
      accounts.error.status === 401
    )
      onUnauthorized();
  }, [accounts.error, onUnauthorized]);
  const queryWindow = useRef<api.UsageFilters["window"]>(undefined);
  const requestsHeading = useRef<HTMLHeadingElement>(null);
  const activeNavigation = useRef<UsageNavigation | null>(null);
  const restoringNavigation = useRef(false);
  const [navigationNotice, setNavigationNotice] = useState("");
  useEffect(() => {
    const remember = () => {
      if (activeNavigation.current && !restoringNavigation.current)
        activeNavigation.current.scroll = window.scrollY;
    };
    window.addEventListener("scroll", remember);
    return () => window.removeEventListener("scroll", remember);
  }, []);
  const [detail, setDetail] = useState<api.UsageReport["rows"][number] | null>(
    null,
  );
  const [draft, setDraft] = useState<api.UsageFilters>(
    () => initialFilters ?? { ...api.defaults(), key: selection?.keyID ?? "" },
  );
  const [applied, setApplied] = useState<api.UsageFilters | null>(null);
  const [options, setOptions] = useState<api.UsageOptions>({
    keys: [],
    models: [],
    failures: [],
  });
  const [customRange, setCustomRange] = useState(false);
  const [policyRead, setPolicyRead] = useState(0);
  const [readAt, setReadAt] = useState<number | null>(null);
  const failedPage = useRef<{
    filters: api.UsageFilters;
    cursors: (string | null)[];
    index: number;
    restore: boolean;
  } | null>(null);
  const [report, setReport] = useState<api.UsageReport | null>(null);
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [stale, setStale] = useState(false);
  const [history, setHistory] = useState<(string | null)[]>([null]),
    [page, setPage] = useState(0);
  const controller = useRef<AbortController | null>(null),
    epoch = useRef(0),
    heading = useRef<HTMLHeadingElement>(null);
  const pendingPosition = useRef<{
    version: number;
    scroll: number | null;
    report: api.UsageReport;
  } | null>(null);
  // A frame can run before React commits a concurrent report render. Position
  // only after its rows exist, otherwise the loading layout clamps POP to zero.
  useLayoutEffect(() => {
    const pending = pendingPosition.current;
    if (
      !pending ||
      pending.version !== epoch.current ||
      pending.report !== report
    )
      return;
    pendingPosition.current = null;
    if (pending.scroll !== null) {
      window.scrollTo?.(0, pending.scroll);
      restoringNavigation.current = false;
    } else {
      requestsHeading.current?.scrollIntoView?.({ block: "start" });
      requestsHeading.current?.focus({ preventScroll: true });
    }
  });
  const unauthorized = useRef(onUnauthorized);
  unauthorized.current = onUnauthorized;
  const lastApplied = useRef(applied);
  lastApplied.current = applied;
  const lastDraft = useRef(draft);
  lastDraft.current = draft;
  const initial = useRef(initialFilters);
  initial.current = initialFilters;
  const filterIdentity = JSON.stringify(initialFilters);
  const optionsLoaded = useRef(false);
  async function load(
    filters: api.UsageFilters,
    cursors: (string | null)[] = [null],
    index = 0,
    restore = false,
    pagination = false,
  ) {
    controller.current?.abort();
    const abort = new AbortController();
    controller.current = abort;
    const version = ++epoch.current;
    // Capture before the read: route/layout scroll events during a slow restore
    // must not replace the saved position with the temporary loading position.
    const restoreScroll = activeNavigation.current?.scroll ?? 0;
    restoringNavigation.current = restore;
    setBusy(true);
    setError("");
    failedPage.current = null;
    try {
      const parameters = api.usageParameters(
        {
          ...filters,
          window:
            cursors.length > 1 || restore ? queryWindow.current : undefined,
        },
        cursors[index],
      );
      const requestFilters = {
        ...filters,
        window: {
          start: Number(parameters.get("start")),
          end: Number(parameters.get("end")),
        },
      };
      if (!optionsLoaded.current) {
        const next = await api.fetchUsageOptions(abort.signal);
        if (version !== epoch.current || abort.signal.aborted) return;
        setOptions(next);
        optionsLoaded.current = true;
      }
      const next = await queryClient.fetchQuery({
        queryKey: ["usage", requestFilters, cursors[index]],
        queryFn: ({ signal }) =>
          api.fetchUsage(
            requestFilters,
            cursors[index],
            AbortSignal.any([signal, abort.signal]),
          ),
        staleTime: 0,
        gcTime: 0,
      });
      if (version !== epoch.current || abort.signal.aborted) return;
      queryWindow.current = requestFilters.window;
      pendingPosition.current =
        restore || index !== page
          ? { version, report: next, scroll: restore ? restoreScroll : null }
          : null;
      setReport(next);
      setReadAt(Date.now());
      setPolicyRead((value) => value + 1);
      setApplied({ ...filters });
      const navigation: UsageNavigation = {
        history: cursors,
        page: index,
        window: requestFilters.window,
        scroll: restore ? restoreScroll : 0,
      };
      activeNavigation.current = navigation;
      onApplied?.(filters, navigation);
      setHistory(cursors);
      setPage(index);
      setStale(false);
    } catch (cause) {
      if (version !== epoch.current || abort.signal.aborted) return;
      if (cause instanceof ManagementError && cause.status === 401) {
        setReport(null);
        setDetail(null);
        setOptions({ keys: [], models: [], failures: [] });
        unauthorized.current();
      } else {
        if (
          restore &&
          index > 0 &&
          cause instanceof ManagementError &&
          cause.status === 400
        ) {
          setNavigationNotice(
            "原分页已失效，已返回请求明细第一页，请重新核对记录。",
          );
          void load(filters);
          return;
        }
        setStale(true);
        if (pagination || restore)
          failedPage.current = { filters, cursors, index, restore };
        setError(
          cause instanceof ManagementError && cause.status === 400
            ? "请检查 UTC 日期与筛选条件，范围最多 31 天。"
            : cause instanceof ManagementError && cause.status === 404
              ? "用量查询尚未开启。"
              : "查询失败或繁忙。可缩小区间后重试。",
        );
      }
    } finally {
      if (version === epoch.current && !abort.signal.aborted) setBusy(false);
    }
  }
  useEffect(() => {
    if (paused) {
      ++epoch.current;
      controller.current?.abort();
      setBusy(false);
      return;
    }
    const next =
      initial.current ??
      (selection
        ? { ...lastDraft.current, key: selection.keyID }
        : (lastApplied.current ?? lastDraft.current));
    if (
      initial.current &&
      JSON.stringify(lastApplied.current) === JSON.stringify(next) &&
      requestedPage === page
    )
      return () => {
        // Numeric owner generation, not a rendered DOM reference.
        // eslint-disable-next-line react-hooks/exhaustive-deps
        ++epoch.current;
        // Abort the most recent owned read, not a DOM element captured at mount.
        // eslint-disable-next-line react-hooks/exhaustive-deps
        controller.current?.abort();
      };
    setDraft(next);
    const saved = restoreView
      ? (navigationStore?.get(usageNavigationKey(next, requestedPage)) as
          UsageNavigation | undefined)
      : undefined;
    if (
      saved &&
      saved.page === requestedPage &&
      requestedPage < saved.history.length
    ) {
      queryWindow.current = saved.window;
      activeNavigation.current = { ...saved };
      void load(next, saved.history, requestedPage, true);
    } else {
      activeNavigation.current = null;
      window.scrollTo?.(0, 0);
      if (requestedPage > 0)
        setNavigationNotice("原分页信息不可用，已返回请求明细第一页。");
      void load(next);
    }
    if (selection) heading.current?.scrollIntoView?.({ block: "start" });
    return () => {
      // Numeric owner generation intentionally retires the last owned read.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      ++epoch.current;
      controller.current?.abort();
    };
    // The parent owns authentication; this effect owns the read-only view's requests.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selection, paused, filterIdentity, requestedPage, restoreView]);
  function update(name: keyof api.UsageFilters, value: string | boolean) {
    setDraft((previous) => ({
      ...previous,
      [name]: value,
      ...(["start", "end"].includes(name) ? { range: undefined } : {}),
    }));
  }
  function submit(event: FormEvent) {
    event.preventDefault();
    if (!busy && !paused) void load({ ...draft });
  }
  const currentPreset =
    applied?.range === "24h"
      ? 1
      : [7, 30].find(
          (days) =>
            applied?.end === new Date().toISOString().slice(0, 10) &&
            applied?.start ===
              new Date(Date.now() - (days - 1) * 86400000)
                .toISOString()
                .slice(0, 10),
        );
  if (paused)
    return (
      <section>
        <p role="status">管理操作进行中，用量查询暂缓。</p>
      </section>
    );
  return (
    <Paper
      withBorder
      p="md"
      radius="md"
      className={styles.workspace}
      component="section"
      aria-labelledby="usage-heading"
    >
      <Title
        order={2}
        id="usage-heading"
        ref={heading}
        className={initialFilters ? "visually-hidden" : undefined}
      >
        用量与请求诊断
      </Title>
      <Group mb="sm">
        {[1, 7, 30].map((days) => (
          <Button
            key={days}
            variant={currentPreset === days ? "filled" : "default"}
            aria-pressed={currentPreset === days}
            disabled={busy}
            onClick={() => {
              const now = new Date();
              const next: api.UsageFilters = {
                ...draft,
                range: days === 1 ? "24h" : undefined,
                start: new Date(now.getTime() - (days - 1) * 86400000)
                  .toISOString()
                  .slice(0, 10),
                end: now.toISOString().slice(0, 10),
              };
              setDraft(next);
              void load(next);
            }}
          >
            {days === 1 ? "最近 24 小时" : `最近 ${days} 天`}
          </Button>
        ))}
        <Button
          variant={!currentPreset ? "filled" : "default"}
          aria-pressed={!currentPreset}
          onClick={() => setCustomRange((value) => !value)}
          aria-expanded={customRange}
        >
          自定义
        </Button>
      </Group>
      <form onSubmit={submit}>
        <div className={styles.filters}>
          <NativeSelect
            label="Key 主体"
            value={draft.key}
            disabled={busy}
            onChange={(e) => update("key", e.currentTarget.value)}
            data={[
              { value: "", label: "全部 Key" },
              ...[
                ...new Set([
                  ...options.keys,
                  ...(draft.key ? [draft.key] : []),
                ]),
              ].map((id) => ({
                value: id,
                label: options.keyOptions?.find((k) => k.id === id)?.displayName
                  ? `${options.keyOptions.find((k) => k.id === id)!.displayName} · ${options.keyOptions.find((k) => k.id === id)!.principal ?? id}`
                  : (options.keyOptions?.find((k) => k.id === id)?.principal ??
                    `主体未记录 · ${id}`),
              })),
            ]}
          />
          <TextInput
            label="模型"
            list="usage-model-options"
            value={draft.model}
            maxLength={128}
            placeholder="全部模型，可输入历史模型"
            disabled={busy}
            onChange={(e) => update("model", e.currentTarget.value)}
          />
          <datalist id="usage-model-options">
            {options.models.map((model) => (
              <option key={model} value={model} />
            ))}
          </datalist>
          <Group align="end">
            <Checkbox
              label="仅异常结果"
              checked={draft.failedOnly}
              disabled={busy}
              onChange={(e) => update("failedOnly", e.currentTarget.checked)}
            />
            <Button type="submit" disabled={busy}>
              {busy ? "正在查询…" : "查询用量"}
            </Button>
          </Group>
        </div>
        {customRange && (
          <div className={styles.dateFilters}>
            {" "}
            <TextInput
              label="起始日（UTC）"
              aria-label="起始日（UTC）"
              type="date"
              value={draft.start}
              disabled={busy}
              required
              onChange={(e) => update("start", e.currentTarget.value)}
            />
            <TextInput
              label="结束日（UTC）"
              aria-label="结束日（UTC）"
              type="date"
              value={draft.end}
              disabled={busy}
              required
              onChange={(e) => update("end", e.currentTarget.value)}
            />
          </div>
        )}
        <details className={styles.moreFilters}>
          <summary>更多筛选</summary>
          <div className={styles.advancedFilters}>
            {" "}
            <NativeSelect
              label="执行模式"
              value={draft.mode}
              disabled={busy}
              onChange={(e) => update("mode", e.currentTarget.value)}
              data={[
                { value: "", label: "全部模式" },
                ...Object.entries(modes).map(([value, label]) => ({
                  value,
                  label,
                })),
              ]}
            />
            <NativeSelect
              label="错误分类"
              value={draft.failure}
              disabled={busy}
              onChange={(e) => update("failure", e.currentTarget.value)}
              data={[
                { value: "", label: "全部分类" },
                ...options.failures.map((value) => ({
                  value,
                  label: failures[value] ?? "其他异常",
                })),
              ]}
            />
            <NativeSelect
              label="用量状态"
              value={draft.state}
              disabled={busy}
              onChange={(e) => update("state", e.currentTarget.value)}
              data={[
                { value: "", label: "全部状态" },
                ...Object.entries(states).map(([value, label]) => ({
                  value,
                  label,
                })),
              ]}
            />
          </div>
        </details>
      </form>
      {error && !failedPage.current && (
        <ErrorState retry={() => void load({ ...draft })}>
          {error}
          {readAt !== null
            ? ` 保留上次成功快照（${localTime(readAt / 1000)}）。`
            : ""}
        </ErrorState>
      )}
      {navigationNotice && (
        <Text role="status" size="sm">
          {navigationNotice}
        </Text>
      )}
      {error && failedPage.current && !report && (
        <ErrorState
          retryLabel="重试翻页"
          retry={() => {
            const failed = failedPage.current;
            if (failed)
              void load(
                failed.filters,
                failed.cursors,
                failed.index,
                failed.restore,
                true,
              );
          }}
        >
          {error}
        </ErrorState>
      )}
      {busy && !report && <LoadingState>正在读取用量…</LoadingState>}
      {report && (
        <div aria-busy={busy} className={stale ? styles.stale : undefined}>
          <p className={styles.hint} aria-label="当前结果筛选">
            当前结果：
            {applied?.range === "24h"
              ? `${utc(report.startUnixSeconds)} 至 ${utc(report.endUnixSeconds)} 前`
              : `${applied?.start} 至 ${applied?.end}（UTC）`}{" "}
            ·{" "}
            {options.keyOptions?.find((k) => k.id === applied?.key)
              ?.displayName ??
              options.keyOptions?.find((k) => k.id === applied?.key)
                ?.principal ??
              (applied?.key || "全部 Key")}
            {applied?.model ? ` · 模型 ${applied.model}` : ""}
            {applied?.mode ? ` · ${modes[applied.mode]}` : ""}
            {applied?.failure
              ? ` · ${failures[applied.failure] ?? "其他异常"}`
              : ""}
            {applied?.state ? ` · ${states[applied.state]}` : ""}
            {applied?.failedOnly ? " · 仅异常结果" : ""}
            {stale ? " · 上次成功快照" : ""}
          </p>
          <details className={styles.method}>
            <summary>统计口径</summary>
            <p className={styles.hint}>
              按准入 UTC 时间统计，起止日均包含；最近 24 小时按已完成 UTC
              小时查询。轮换保留原 Key
              历史，迟到用量更新原时段；每次查询为新账本快照。拒绝诊断查询最近
              30
              天、最多一万条，压力或存储失败时可能缺失，不作为全部流量计数。每页最多
              50 条，不包含请求或响应正文。
            </p>
          </details>
          <UsageSummary report={report} />
          <UsageTrend report={report} />
          <details className={styles.moreFilters}>
            <summary>更多统计与用量证据</summary>
            <UsageEvidence report={report} expanded />
            <KeyLimitsSummary
              key={applied?.key ?? ""}
              keyID={applied?.key ?? ""}
              refresh={policyRead}
            />
            <Text
              className={styles.governance}
              size="sm"
              my="md"
              title="缺少完整用量的请求仍保留占用；更改时间范围不会释放。占用不能代表实际费用上界。"
            >
              {report.lifetimeGovernance.keyID ? "当前 Key" : "全部 Key"}{" "}
              {terms.exposure}（不受其他筛选影响）：
              {report.lifetimeGovernance.inFlight} 在途、
              {report.lifetimeGovernance.unknown} {terms.pending}，
              {money(report.lifetimeGovernance.exposureMicros)} ⓘ
              <br />
              区间{terms.exposure}：
              {money(report.totals.unresolvedExposureMicros)}
            </Text>
            {report.totals.historicalWithoutTime > 0 && (
              <p className={styles.warning}>
                另有 {report.totals.historicalWithoutTime}{" "}
                条符合其他筛选的历史执行缺少精确准入时间，未纳入本区间；它们仍可能占用待核对占用（预估）。
              </p>
            )}
          </details>
          <h3
            ref={requestsHeading}
            tabIndex={-1}
            className={styles.requestsHeading}
          >
            请求明细
          </h3>
          <UsageRequests
            rows={report.rows}
            onDetail={setDetail}
            retry={() => {
              if (applied) void load(applied, history, page);
            }}
          />
          {error && failedPage.current && (
            <ErrorState
              retryLabel="重试翻页"
              retry={() => {
                const failed = failedPage.current;
                if (failed)
                  void load(
                    failed.filters,
                    failed.cursors,
                    failed.index,
                    failed.restore,
                    true,
                  );
              }}
            >
              第 {failedPage.current.index + 1} 页读取失败。{error}
              {readAt !== null
                ? ` 保留上次成功快照（${localTime(readAt / 1000)}）。`
                : ""}
            </ErrorState>
          )}
          <div className={styles.pagination} aria-label="请求分页">
            <span>第 {page + 1} 页</span>
            <Button
              variant="default"
              disabled={
                busy || (stale && !failedPage.current) || !applied || page === 0
              }
              onClick={() => {
                if (applied) void load(applied, history, page - 1, false, true);
              }}
            >
              上一页
            </Button>
            <Button
              variant="default"
              disabled={
                busy ||
                (stale && !failedPage.current) ||
                !applied ||
                !report.nextCursor ||
                history.length >= 2201
              }
              onClick={() => {
                if (applied && report.nextCursor)
                  void load(
                    applied,
                    [...history.slice(0, page + 1), report.nextCursor],
                    page + 1,
                    false,
                    true,
                  );
              }}
            >
              下一页
            </Button>
          </div>
        </div>
      )}
      <UsageDetail
        accounts={accounts.data}
        detail={detail}
        onClose={() => setDetail(null)}
      />
    </Paper>
  );
}
