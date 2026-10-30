import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { ManagementError } from "../../shared/management";
import * as api from "./api";
import { KeyLimitsSummary } from "../key-management/KeyLimitsSummary";
import {
  Alert,
  Button,
  Checkbox,
  Drawer,
  Group,
  NativeSelect,
  Paper,
  Stack,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import {
  failures,
  modes,
  states,
  outcomes,
  terms,
  metricLabels,
  money,
  localTime,
  timeTitle,
  estimateNote,
} from "../../shared/presentation";
export { failures } from "../../shared/presentation";
function number(value: string | null | undefined, lower = false) {
  return value == null
    ? "不可用"
    : (lower ? "≥ " : "") + BigInt(value).toLocaleString("zh-CN");
}
function utc(value: number) {
  return new Date(value * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(".000Z", " UTC");
}
function Trend({ report }: { report: api.UsageReport }) {
  const daily = report.buckets.length > 168;
  const grouped = new Map<
    number,
    { admitted: number; rejected: number; unresolved: number }
  >();
  for (const point of report.buckets) {
    const at = daily
      ? Math.floor(point.atUnixSeconds / 86400) * 86400
      : point.atUnixSeconds;
    const item = grouped.get(at) ?? { admitted: 0, rejected: 0, unresolved: 0 };
    item.admitted += point.admitted;
    item.rejected += point.recordedRejections;
    item.unresolved += point.unresolved;
    grouped.set(at, item);
  }
  const points = [...grouped],
    maximum = Math.max(
      1,
      ...points.flatMap(([, item]) => [item.admitted, item.rejected]),
    );
  return (
    <div className="usage-trend">
      <h3>
        请求趋势 <small>UTC · 按{daily ? "日" : "小时"}</small>
      </h3>
      <div className="trend-legend">
        <span>■ 已准入</span>
        <span>■ 已记录准入前拒绝</span>
      </div>
      <svg
        role="img"
        aria-label={`UTC 按${daily ? "日" : "小时"}请求趋势，已准入 ${report.totals.admitted}，已记录拒绝 ${report.totals.recordedRejections}`}
        viewBox={`0 0 ${Math.max(240, points.length * 20)} 120`}
        preserveAspectRatio="none"
      >
        {points.map(([at, item], index) => (
          <g key={at}>
            <title>
              {utc(at)} · 已准入 {item.admitted} · 已记录拒绝 {item.rejected} ·
              待核对 {item.unresolved}
            </title>
            <rect
              x={index * 20}
              y={110 - (item.admitted / maximum) * 100}
              width="8"
              height={(item.admitted / maximum) * 100}
              fill="#286453"
            />
            <rect
              x={index * 20 + 9}
              y={110 - (item.rejected / maximum) * 100}
              width="8"
              height={(item.rejected / maximum) * 100}
              fill="#ba8230"
            />
          </g>
        ))}
      </svg>
      <div className="trend-period">
        <small>{utc(report.startUnixSeconds)}</small>
        <small>{utc(report.endUnixSeconds)} 前</small>
      </div>
    </div>
  );
}
export function UsageOverview({
  selection,
  paused,
  onUnauthorized,
  initialFilters,
  onApplied,
}: {
  selection: { keyID: string; sequence: number } | null;
  paused: boolean;
  onUnauthorized: () => void;
  initialFilters?: api.UsageFilters;
  onApplied?: (filters: api.UsageFilters) => void;
}) {
  const queryClient = useQueryClient();
  const [detail, setDetail] = useState<api.UsageReport["rows"][number] | null>(
    null,
  );
  const [copied, setCopied] = useState("");
  const [draft, setDraft] = useState<api.UsageFilters>(
    () => initialFilters ?? { ...api.defaults(), key: selection?.keyID ?? "" },
  );
  const [applied, setApplied] = useState<api.UsageFilters | null>(null);
  const [options, setOptions] = useState<api.UsageOptions>({
    keys: [],
    models: [],
    failures: [],
  });
  const [policyRead, setPolicyRead] = useState(0);
  const [report, setReport] = useState<api.UsageReport | null>(null);
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [stale, setStale] = useState(false);
  const [history, setHistory] = useState<(string | null)[]>([null]),
    [page, setPage] = useState(0);
  const controller = useRef<AbortController | null>(null),
    epoch = useRef(0),
    heading = useRef<HTMLHeadingElement>(null);
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
  ) {
    controller.current?.abort();
    const abort = new AbortController();
    controller.current = abort;
    const version = ++epoch.current;
    setBusy(true);
    setError("");
    try {
      api.usageParameters(filters, cursors[index]);
      if (!optionsLoaded.current) {
        const next = await api.fetchUsageOptions(abort.signal);
        if (version !== epoch.current || abort.signal.aborted) return;
        setOptions(next);
        optionsLoaded.current = true;
      }
      const next = await queryClient.fetchQuery({
        queryKey: ["usage", filters, cursors[index]],
        queryFn: ({ signal }) =>
          api.fetchUsage(
            filters,
            cursors[index],
            AbortSignal.any([signal, abort.signal]),
          ),
        retry: false,
        staleTime: 0,
        gcTime: 0,
      });
      if (version !== epoch.current || abort.signal.aborted) return;
      setReport(next);
      setPolicyRead((value) => value + 1);
      setApplied({ ...filters });
      onApplied?.(filters);
      setHistory(cursors);
      setPage(index);
      setStale(false);
    } catch (cause) {
      if (version !== epoch.current || abort.signal.aborted) return;
      if (cause instanceof ManagementError && cause.status === 401) {
        setReport(null);
        setDetail(null);
        setCopied("");
        setOptions({ keys: [], models: [], failures: [] });
        unauthorized.current();
      } else {
        setStale(true);
        setError(
          cause instanceof ManagementError && cause.status === 400
            ? "请检查 UTC 日期与筛选条件，范围最多 31 天。"
            : cause instanceof ManagementError && cause.status === 404
              ? "用量查询尚未开启。"
              : "查询失败或繁忙。可缩小区间后重试；下方保留上次成功快照。",
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
      JSON.stringify(lastApplied.current) === JSON.stringify(next)
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
    void load(next);
    if (selection) heading.current?.scrollIntoView?.({ block: "start" });
    return () => {
      // Numeric owner generation intentionally retires the last owned read.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      ++epoch.current;
      controller.current?.abort();
    };
    // The parent owns authentication; this effect owns the read-only view's requests.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selection, paused, filterIdentity]);
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
  if (paused)
    return (
      <section className="panel usage-panel">
        <p role="status">管理操作进行中，用量查询暂缓。</p>
      </section>
    );
  const incomplete =
    !!report && report.totals.partial + report.totals.unavailable > 0;
  return (
    <Paper
      withBorder
      p="lg"
      radius="md"
      className="usage-workspace"
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
      <details className="usage-method">
        <summary>统计口径</summary>
        <p className="field-hint">
          按准入 UTC 时间统计，起止日均包含。轮换保留原 Key
          历史；迟到用量会更新原时段。每次查询为新的账本快照。
        </p>
      </details>
      <Text size="xs" c="dimmed" mb="xs">
        最近 24 小时按已完成 UTC 小时查询；日期筛选包含起止日。
      </Text>
      <Group mb="md">
        {[1, 7, 30].map((days) => (
          <Button
            key={days}
            variant="light"
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
      </Group>
      <form onSubmit={submit}>
        <div className="responsive-grid responsive-grid-4 grid-gap-bottom">
          <TextInput
            label="起始日（UTC）"
            type="date"
            value={draft.start}
            disabled={busy}
            required
            onChange={(e) => update("start", e.currentTarget.value)}
          />
          <TextInput
            label="结束日（UTC）"
            type="date"
            value={draft.end}
            disabled={busy}
            required
            onChange={(e) => update("end", e.currentTarget.value)}
          />
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
                label:
                  options.keyOptions?.find((k) => k.id === id)?.principal ??
                  `主体未记录 · ${id}`,
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
          <Group>
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
      </form>
      {error && (
        <Alert role="alert" color="red">
          {error}
        </Alert>
      )}
      {report && (
        <div aria-busy={busy} className={stale ? "usage-stale" : undefined}>
          <p className="field-hint">
            当前结果：
            {applied?.range === "24h"
              ? `${utc(report.startUnixSeconds)} 至 ${utc(report.endUnixSeconds)} 前`
              : `${applied?.start} 至 ${applied?.end}（UTC）`}{" "}
            ·{" "}
            {options.keyOptions?.find((k) => k.id === applied?.key)
              ?.principal ??
              (applied?.key || "全部 Key")}
            {stale ? " · 上次成功快照" : ""}
          </p>
          {(stale ||
            applied?.model ||
            applied?.mode ||
            applied?.failure ||
            applied?.state ||
            applied?.failedOnly) && (
            <p className="field-hint" aria-label="当前结果筛选">
              结果筛选：模型 {applied?.model || "全部"} · 模式{" "}
              {applied?.mode ? modes[applied.mode] : "全部"} · 错误{" "}
              {applied?.failure
                ? (failures[applied.failure] ?? "其他异常")
                : "全部"}{" "}
              · 用量状态 {applied?.state ? states[applied.state] : "全部"} ·{" "}
              {applied?.failedOnly ? "仅异常结果" : "全部结果"}
            </p>
          )}
          <div className="usage-summary">
            <div>
              <span>请求</span>
              <strong>{report.totals.admitted.toLocaleString()}</strong>
              <small>生成 / 预热 / 压缩</small>
            </div>
            <div>
              <span>已记录准入前拒绝</span>
              <strong>
                {report.totals.recordedRejections.toLocaleString()}
              </strong>
              <small>未启动执行</small>
            </div>
            <div>
              <span>区间待核对</span>
              <strong>
                {(
                  report.totals.inFlight + report.totals.unknown
                ).toLocaleString()}
              </strong>
              <small>
                {report.totals.inFlight} 在途 · {report.totals.unknown} 待核对
              </small>
            </div>
            <div>
              <span>失败 / 取消</span>
              <strong>
                {report.totals.failed} / {report.totals.cancelled}
              </strong>
              <small>结果与用量完整度独立</small>
            </div>
            <div>
              <span>用量完整度</span>
              <strong>{report.totals.complete} 完整</strong>
              <small>
                {report.totals.partial} 部分 · {report.totals.unavailable}{" "}
                不可用
              </small>
            </div>
          </div>
          <div className="usage-metrics">
            {(
              Object.entries(metricLabels) as [keyof api.Metrics, string][]
            ).map(([field, title]) => (
              <div key={field}>
                <span>{title}</span>
                <strong>
                  {report.totals.admitted === 0
                    ? "—"
                    : field === "estimatedMicros"
                      ? money(report.totals.metrics[field])
                      : number(report.totals.metrics[field], incomplete)}
                </strong>
              </div>
            ))}
          </div>
          <p className="field-hint">
            {incomplete
              ? "含不完整/缺失证据：数值只表示已观测下界，未知部分无法量化，不能当零。"
              : estimateNote}{" "}
            图片工具 token 与宿主响应 token
            分别统计，不相加；缺失工具证据显示不可用。
          </p>
          <KeyLimitsSummary
            key={applied?.key ?? ""}
            keyID={applied?.key ?? ""}
            refresh={policyRead}
          />
          <Text
            className="governance-note"
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
            <p className="warning-banner">
              另有 {report.totals.historicalWithoutTime}{" "}
              条符合其他筛选的历史执行缺少精确准入时间，未纳入本区间；它们仍可能占用待核对占用（预估）。
            </p>
          )}
          <Trend report={report} />
          <h3>请求明细</h3>
          <p className="field-hint">
            拒绝诊断查询最近 30
            天、最多一万条，压力或存储失败时可能缺失，不作为全部流量计数。每页最多
            50 条，不包含请求或响应正文。
          </p>
          {!report.rows.length ? (
            <p className="empty-state">此筛选下没有已记录请求。</p>
          ) : (
            <div className="table-scroll">
              <Table className="usage-table" highlightOnHover>
                <thead>
                  <tr>
                    <th>准入/记录时间</th>
                    <th>Key / 模型</th>
                    <th>归属 / 模式</th>
                    <th>请求结果</th>
                    <th>用量</th>
                    <th>详情</th>
                  </tr>
                </thead>
                <tbody>
                  {report.rows.map((row) => (
                    <tr key={row.kind + row.id}>
                      <td data-label="准入/记录时间">
                        <span title={timeTitle(row.atUnixSeconds)}>
                          {localTime(row.atUnixSeconds)}
                        </span>
                        <small
                          className="key-id"
                          title={row.requestID ?? row.id}
                        >
                          {row.requestID ?? row.id}
                        </small>
                      </td>
                      <td data-label="Key / 模型">
                        <span title={row.keyID}>
                          {row.principal ?? "主体未记录"}
                        </span>
                        <small>{row.model ?? "模型未记录"}</small>
                      </td>
                      <td data-label="归属 / 模式">
                        {row.accountID ?? "未派发"}
                        <small>{modes[row.mode]}</small>
                      </td>
                      <td data-label="请求结果">
                        {row.kind === "rejected"
                          ? "准入前拒绝"
                          : row.outcome
                            ? outcomes[row.outcome]
                            : "结果未记录"}
                        <small>
                          {row.failure
                            ? (failures[row.failure] ?? "其他异常")
                            : ""}
                        </small>
                        <small>
                          {row.state ? states[row.state] : "无执行租约"}
                        </small>
                      </td>
                      <td data-label="用量">
                        {row.kind === "rejected" ? (
                          "无执行用量"
                        ) : (
                          <>
                            {row.completeness === null
                              ? "不可用"
                              : row.completeness === "partial"
                                ? "部分证据，下界"
                                : "完整证据"}
                            <small>
                              输入{" "}
                              {number(
                                row.metrics.inputTokens,
                                row.completeness === "partial",
                              )}{" "}
                              · 输出{" "}
                              {number(
                                row.metrics.outputTokens,
                                row.completeness === "partial",
                              )}
                            </small>
                            <small>{money(row.metrics.estimatedMicros)}</small>
                            <small>
                              缓存 {number(row.metrics.cachedTokens)} · 图片输入{" "}
                              {number(row.metrics.imageInputTokens)} · 图片输出{" "}
                              {number(row.metrics.imageOutputTokens)}
                            </small>
                          </>
                        )}
                      </td>
                      <td data-label="详情">
                        <Button
                          variant="subtle"
                          size="compact-sm"
                          onClick={() => {
                            setDetail(row);
                            setCopied("");
                          }}
                        >
                          查看详情
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            </div>
          )}
          <div className="usage-pagination">
            <span>第 {page + 1} 页</span>
            <Button
              className="secondary"
              disabled={busy || stale || !applied || page === 0}
              onClick={() => {
                if (applied) void load(applied, history, page - 1);
              }}
            >
              上一页
            </Button>
            <Button
              className="secondary"
              disabled={
                busy ||
                stale ||
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
                  );
              }}
            >
              下一页
            </Button>
          </div>
        </div>
      )}
      <Drawer
        opened={!!detail}
        onClose={() => {
          setDetail(null);
          setCopied("");
        }}
        title="请求详情"
        position="right"
        size="lg"
        closeButtonProps={{ "aria-label": "关闭" }}
      >
        {detail && (
          <Stack>
            <Text style={{ overflowWrap: "anywhere" }}>
              请求 ID：{detail.requestID ?? detail.id}
            </Text>
            <Button
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(
                    detail.requestID ?? detail.id,
                  );
                  setCopied("已复制请求 ID");
                } catch {
                  setCopied("复制失败，请手动选择请求 ID");
                }
              }}
            >
              复制请求 ID
            </Button>
            {copied && <Text role="status">{copied}</Text>}
            <Text title={timeTitle(detail.atUnixSeconds)}>
              {localTime(detail.atUnixSeconds)} / {utc(detail.atUnixSeconds)}
            </Text>
            <Text>
              Key：{detail.principal ?? "主体未记录"} · {detail.keyID}
            </Text>
            <Text>
              账号：{detail.accountID ?? "未派发"} · 模型：
              {detail.model ?? "未记录"} · {modes[detail.mode]}
            </Text>
            <Text>
              结果：{detail.outcome ? outcomes[detail.outcome] : "未记录"} ·{" "}
              {detail.state ? states[detail.state] : "无执行租约"}
            </Text>
            <Text>
              错误：
              {detail.failure
                ? (failures[detail.failure] ?? "其他异常")
                : "无已记录错误"}
            </Text>
            <Text>
              首事件耗时：
              {detail.firstEventMilliseconds == null
                ? "不可用"
                : `${detail.firstEventMilliseconds} ms`}{" "}
              · 总耗时：
              {detail.totalMilliseconds == null
                ? "不可用"
                : `${detail.totalMilliseconds} ms`}
            </Text>
            <Text size="sm">
              耗时从准入后开始观测；历史记录或无首事件时不可用。{estimateNote}。
            </Text>
            <Text>
              用量：
              {detail.completeness === "complete"
                ? "完整"
                : detail.completeness === "partial"
                  ? "部分证据，数值为下界"
                  : "不可用"}
            </Text>
            {Object.entries(metricLabels).map(([key, label]) => (
              <Text key={key}>
                {label}：
                {key === "estimatedMicros"
                  ? money(detail.metrics.estimatedMicros)
                  : number(
                      detail.metrics[key as keyof api.Metrics],
                      detail.completeness === "partial",
                    )}
              </Text>
            ))}
          </Stack>
        )}
      </Drawer>
    </Paper>
  );
}
