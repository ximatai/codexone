import { PrivateName, usePrivacyMask } from "../../shared/privacy-mask";
import { businessDate, timezone } from "../../shared/business-day";
import { isUTCDateInput } from "../../shared/date-input";
import { DateInput } from "@mantine/dates";
import { UsageDisclosure } from "./UsageDisclosure";
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
  Select,
  Autocomplete,
  Paper,
  Text,
  TextInput,
  Title,
  UnstyledButton,
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
import { rejectionReason, utc } from "./format";
export { duration } from "./format";
export { failures } from "../../shared/presentation";

// Keep the calendars below the fields so they cannot cover the range toggle.
const datePopoverProps = { middlewares: { flip: false } };

export interface UsageNavigation {
  history: (string | null)[];
  page: number;
  window: api.UsageFilters["window"];
  scroll: number;
  rejectionOrigin?: RejectionOrigin;
}
type RejectionOrigin = {
  filters: api.UsageFilters;
  navigation: UsageNavigation;
};
type ReadPosition = {
  window: api.UsageFilters["window"];
  scroll?: number;
  rejectionOrigin?: RejectionOrigin;
};
export function usageNavigationKey(filters: api.UsageFilters, page: number) {
  const ordered = Object.fromEntries(
    Object.entries({ ...filters, offsetMinutes: undefined }).sort(([a], [b]) =>
      a.localeCompare(b),
    ),
  );
  return `usage:${JSON.stringify(ordered)}:page:${page}`;
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
  const masked = usePrivacyMask();
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
    () =>
      initialFilters ?? {
        ...api.defaults(),
        start: "",
        end: "",
        key: selection?.keyID ?? "",
      },
  );
  const [applied, setApplied] = useState<api.UsageFilters | null>(null);
  const [options, setOptions] = useState<api.UsageOptions>({
    keys: [],
    models: [],
    failures: [],
  });
  const [customRange, setCustomRange] = useState(false);
  const [invalidDates, setInvalidDates] = useState({
    start: false,
    end: false,
  });
  const [policyRead, setPolicyRead] = useState(0);
  const [readAt, setReadAt] = useState<number | null>(null);
  const failedPage = useRef<{
    filters: api.UsageFilters;
    cursors: (string | null)[];
    index: number;
    restore: boolean;
    position?: ReadPosition;
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
  // The view this owner last reported through onApplied. Its URL echo must not
  // retire a newer read the user started meanwhile (for example the next page).
  const appliedEcho = useRef<string | null>(null);
  const optionsLoaded = useRef(false);
  useEffect(
    () => () => {
      // Unmount retires whichever read is current; route echoes do not.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      ++epoch.current;
      // eslint-disable-next-line react-hooks/exhaustive-deps
      controller.current?.abort();
    },
    [],
  );
  async function load(
    filters: api.UsageFilters,
    cursors: (string | null)[] = [null],
    index = 0,
    restore = false,
    pagination = false,
    position?: ReadPosition,
  ) {
    controller.current?.abort();
    const abort = new AbortController();
    controller.current = abort;
    const version = ++epoch.current;
    // Capture before the read: route/layout scroll events during a slow restore
    // must not replace the saved position with the temporary loading position.
    const restoreScroll =
      position?.scroll ?? activeNavigation.current?.scroll ?? 0;
    restoringNavigation.current = restore;
    setBusy(true);
    setError("");
    failedPage.current = null;
    try {
      const nextOptions = await api.fetchUsageOptions(abort.signal);
      if (version !== epoch.current || abort.signal.aborted) return;
      const offsetMinutes = nextOptions.businessDay?.offsetMinutes ?? 0;
      setOptions(nextOptions);
      optionsLoaded.current = true;
      filters = {
        ...filters,
        offsetMinutes,
        start: filters.start || api.defaults(offsetMinutes).start,
        end: filters.end || api.defaults(offsetMinutes).end,
      };
      setDraft(filters);
      const parameters = api.usageParameters(
        {
          ...filters,
          window:
            position?.window ??
            (cursors.length > 1 || restore ? queryWindow.current : undefined),
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
        restore || index !== page || position !== undefined
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
        rejectionOrigin: filters.rejectionGroup
          ? (position?.rejectionOrigin ??
            activeNavigation.current?.rejectionOrigin)
          : undefined,
      };
      activeNavigation.current = navigation;
      appliedEcho.current = usageNavigationKey(filters, index);
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
          void load(filters, [null], 0, false, false, position);
          return;
        }
        setStale(true);
        if (pagination || restore || position)
          failedPage.current = { filters, cursors, index, restore, position };
        setError(
          cause instanceof ManagementError && cause.status === 400
            ? "请检查业务日日期与筛选条件，范围最多 31 天。"
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
    if (initial.current) {
      const identity = usageNavigationKey(next, requestedPage);
      const echo = appliedEcho.current === identity;
      appliedEcho.current = null;
      if (
        lastApplied.current !== null &&
        usageNavigationKey(lastApplied.current, requestedPage) ===
          usageNavigationKey(next, requestedPage) &&
        requestedPage === page
      ) {
        // Navigation back to the shown view supersedes an in-flight read; the
        // echo of our own report leaves a newer user read running.
        if (!echo) {
          ++epoch.current;
          controller.current?.abort();
          setBusy(false);
          setDraft(next);
        }
        return;
      }
    }
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
    // A replacing read aborts its predecessor in load(); unmount is owned above.
    // The parent owns authentication; this effect owns the read-only view's requests.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selection, paused, filterIdentity, requestedPage, restoreView]);
  function drillIntoRejections(group: string) {
    if (!applied || !activeNavigation.current) return;
    const navigation = { ...activeNavigation.current, scroll: window.scrollY };

    void load({ ...applied, rejectionGroup: group }, [null], 0, false, false, {
      window: navigation.window,
      rejectionOrigin: { filters: applied, navigation },
    });
  }

  function clearRejectionGroup() {
    if (!applied) return;
    const { rejectionGroup: _, ...filters } = applied;
    const saved = activeNavigation.current?.rejectionOrigin;
    if (
      saved &&
      usageNavigationKey(saved.filters, 0) === usageNavigationKey(filters, 0)
    ) {
      void load(
        saved.filters,
        saved.navigation.history,
        saved.navigation.page,
        true,
        false,
        { window: saved.navigation.window, scroll: saved.navigation.scroll },
      );
    } else {
      void load(filters, [null], 0, false, false, {
        window: queryWindow.current,
      });
    }
  }

  function update(
    name: keyof api.UsageFilters,
    value: string | boolean | undefined,
  ) {
    setDraft((previous) => ({
      ...previous,
      [name]: value,
      ...(name === "rejectedOnly" && !value
        ? { rejectionGroup: undefined }
        : {}),
      ...(["start", "end"].includes(name) ? { range: undefined } : {}),
    }));
  }
  function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || paused) return;
    if (invalidDates.start || invalidDates.end) {
      setCustomRange(true);
      return;
    }
    void load({ ...draft });
  }
  const currentPreset =
    applied?.range === "24h"
      ? 1
      : [7, 30].find(
          (days) =>
            applied?.end ===
              businessDate(
                Date.now() / 1000,
                options.businessDay?.offsetMinutes,
              ) &&
            applied?.start ===
              businessDate(
                Date.now() / 1000 - (days - 1) * 86400,
                options.businessDay?.offsetMinutes,
              ),
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
              const now = new Date(
                Date.now() + (options.businessDay?.offsetMinutes ?? 0) * 60000,
              );
              const next: api.UsageFilters = {
                ...draft,
                range: days === 1 ? "24h" : undefined,
                start: new Date(now.getTime() - (days - 1) * 86400000)
                  .toISOString()
                  .slice(0, 10),
                end: now.toISOString().slice(0, 10),
              };
              setDraft(next);
              setInvalidDates({ start: false, end: false });
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
          <Select
            label="Key 主体"
            value={draft.key}
            disabled={busy}
            onChange={(value) => update("key", value ?? "")}
            allowDeselect={false}
            data={[
              { value: "", label: "全部 Key" },
              ...[
                ...new Set([
                  ...options.keys,
                  ...(draft.key ? [draft.key] : []),
                ]),
              ].map((id, index) => {
                const key = options.keyOptions?.find((item) => item.id === id);
                const label = masked
                  ? `已隐藏 Key ${index + 1}`
                  : key?.displayName
                    ? `${key.displayName} · ${key.principal ?? id}`
                    : (key?.principal ?? `主体未记录 · ${id}`);
                return {
                  value: id,
                  label: label + (key?.archived ? " · 已归档" : ""),
                };
              }),
            ]}
          />
          <Autocomplete
            label="模型"
            data={options.models}
            value={draft.model}
            maxLength={128}
            placeholder="全部模型"
            disabled={busy}
            onChange={(value) => update("model", value)}
          />
          <TextInput
            label="推理强度"
            placeholder="全部强度"
            maxLength={32}
            value={draft.reasoningEffort ?? ""}
            disabled={busy}
            onChange={(e) => update("reasoningEffort", e.currentTarget.value)}
          />
          <Group className={styles.filterActions}>
            <Checkbox
              label="仅异常结果"
              checked={draft.failedOnly}
              disabled={busy}
              onChange={(e) => update("failedOnly", e.currentTarget.checked)}
            />
            <Checkbox
              label="仅准入前拒绝"
              checked={draft.rejectedOnly ?? false}
              disabled={busy}
              onChange={(e) =>
                update("rejectedOnly", e.currentTarget.checked || undefined)
              }
            />
            <Button type="submit" disabled={busy}>
              {busy ? "正在查询…" : "查询用量"}
            </Button>
          </Group>
        </div>
        {customRange && (
          <div className={styles.dateFilters}>
            {" "}
            <DateInput
              label={`起始日（${timezone(options.businessDay?.offsetMinutes)}）`}
              aria-label={`起始日（${timezone(options.businessDay?.offsetMinutes)}）`}
              value={draft.start || null}
              dateParser={(value) => (isUTCDateInput(value) ? value : null)}
              error={
                invalidDates.start ? "请输入有效日期（YYYY-MM-DD）" : undefined
              }
              onInputCapture={(event) => {
                const invalid = !isUTCDateInput(event.currentTarget.value);
                setInvalidDates((previous) => ({
                  ...previous,
                  start: invalid,
                }));
              }}
              locale="zh-cn"
              valueFormat="YYYY-MM-DD"
              getDayProps={(day) => ({ "aria-label": day })}
              popoverProps={datePopoverProps}
              fixOnBlur={false}
              disabled={busy}
              required
              onChange={(value) => {
                update("start", value ?? "");
                setInvalidDates((previous) => ({ ...previous, start: false }));
              }}
            />
            <DateInput
              label={`结束日（${timezone(options.businessDay?.offsetMinutes)}）`}
              aria-label={`结束日（${timezone(options.businessDay?.offsetMinutes)}）`}
              value={draft.end || null}
              dateParser={(value) => (isUTCDateInput(value) ? value : null)}
              error={
                invalidDates.end ? "请输入有效日期（YYYY-MM-DD）" : undefined
              }
              onInputCapture={(event) => {
                const invalid = !isUTCDateInput(event.currentTarget.value);
                setInvalidDates((previous) => ({ ...previous, end: invalid }));
              }}
              locale="zh-cn"
              valueFormat="YYYY-MM-DD"
              getDayProps={(day) => ({ "aria-label": day })}
              popoverProps={datePopoverProps}
              fixOnBlur={false}
              disabled={busy}
              required
              onChange={(value) => {
                update("end", value ?? "");
                setInvalidDates((previous) => ({ ...previous, end: false }));
              }}
            />
          </div>
        )}
        <UsageDisclosure className={styles.moreFilters} title="更多筛选">
          <div className={styles.advancedFilters}>
            {" "}
            <Select
              label="执行模式"
              value={draft.mode}
              disabled={busy}
              onChange={(value) => update("mode", value ?? "")}
              allowDeselect={false}
              data={[
                { value: "", label: "全部模式" },
                ...Object.entries(modes).map(([value, label]) => ({
                  value,
                  label,
                })),
              ]}
            />
            <Select
              label="错误分类"
              value={draft.failure}
              disabled={busy}
              onChange={(value) => update("failure", value ?? "")}
              allowDeselect={false}
              data={[
                { value: "", label: "全部分类" },
                ...options.failures.map((value) => ({
                  value,
                  label: failures[value] ?? "其他异常",
                })),
              ]}
            />
            <Select
              label="请求结果"
              value={draft.outcome ?? ""}
              disabled={busy}
              onChange={(value) => update("outcome", value ?? "")}
              allowDeselect={false}
              data={[
                { value: "", label: "全部结果" },
                { value: "failed", label: "失败" },
              ]}
            />
            <Select
              label="用量状态"
              value={draft.state}
              disabled={busy}
              onChange={(value) => update("state", value ?? "")}
              allowDeselect={false}
              data={[
                { value: "", label: "全部状态" },
                ...Object.entries(states).map(([value, label]) => ({
                  value,
                  label,
                })),
              ]}
            />
          </div>
        </UsageDisclosure>
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
                failed.position,
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
              : `${applied?.start} 至 ${applied?.end}（${timezone(options.businessDay?.offsetMinutes)}）`}{" "}
            ·{" "}
            {applied?.key ? (
              <PrivateName>
                {options.keyOptions?.find((k) => k.id === applied.key)
                  ?.displayName ??
                  options.keyOptions?.find((k) => k.id === applied.key)
                    ?.principal ??
                  applied.key}
              </PrivateName>
            ) : (
              "全部 Key"
            )}
            {applied?.model ? ` · 模型 ${applied.model}` : ""}
            {applied?.reasoningEffort
              ? ` · 推理 ${applied.reasoningEffort}`
              : ""}
            {applied?.mode ? ` · ${modes[applied.mode]}` : ""}
            {applied?.failure
              ? ` · ${failures[applied.failure] ?? "其他异常"}`
              : ""}
            {applied?.state ? ` · ${states[applied.state]}` : ""}
            {applied?.outcome === "failed" ? " · 请求结果：失败" : ""}
            {applied?.rejectedOnly ? " · 仅准入前拒绝" : ""}
            {applied?.failedOnly ? " · 仅异常结果" : ""}
            {stale ? " · 上次成功快照" : ""}
          </p>
          <UsageDisclosure className={styles.method} title="统计口径">
            <p className={styles.hint}>
              按准入业务日统计，起止日均包含；最近 24 小时按已完成 UTC
              小时查询。轮换保留原 Key
              历史，迟到用量更新原时段；每次查询为新账本快照。拒绝诊断查询最近
              30
              天、最多一万条，压力或存储失败时可能缺失，不作为全部流量计数。每页最多
              10 条，不包含请求或响应正文。
            </p>
          </UsageDisclosure>
          {applied?.rejectionGroup && (
            <Button
              variant="subtle"
              size="compact-sm"
              disabled={busy}
              onClick={clearRejectionGroup}
            >
              返回全部拒绝
            </Button>
          )}
          {!!report.rejectionCounts?.length && (
            <section aria-label="拒绝原因汇总">
              <h3>拒绝原因</h3>
              <ul>
                {report.rejectionCounts.map((item) => {
                  const group = `${item.failure}:${item.reason ?? "unrecorded"}`;
                  const label = `${failures[item.failure] ?? "其他异常"} · ${rejectionReason(item.reason)} · ${item.count.toLocaleString("zh-CN")} 条`;
                  return (
                    <li key={group}>
                      {applied?.rejectionGroup ? (
                        label
                      ) : (
                        <UnstyledButton
                          className={styles.rejectionGroup}
                          type="button"
                          disabled={busy}
                          onClick={() => drillIntoRejections(group)}
                        >
                          {label}
                        </UnstyledButton>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          )}
          {!applied?.rejectedOnly && (
            <>
              <UsageSummary report={report} />
              <UsageTrend report={report} />
            </>
          )}
          <UsageDisclosure
            className={styles.moreFilters}
            title="更多统计与用量证据"
          >
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
          </UsageDisclosure>
          <h3
            ref={requestsHeading}
            tabIndex={-1}
            className={styles.requestsHeading}
          >
            请求明细
          </h3>
          <UsageRequests
            rows={report.rows}
            defaultReasoningEfforts={options.defaultReasoningEfforts}
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
                    failed.position,
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
