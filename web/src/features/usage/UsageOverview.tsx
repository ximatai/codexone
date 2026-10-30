import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { ManagementError } from "../../shared/management";
import * as api from "./api";
import { KeyLimitsSummary } from "../key-management/KeyLimitsSummary";
export const failures: Record<string, string> = {
  authentication_rejected: "上游认证拒绝",
  rate_limited: "上游限流",
  upstream_unavailable: "上游暂不可用",
  upstream_rejected: "上游拒绝请求",
  invalid_upstream_response: "上游响应无效",
  deadline_exceeded: "执行期限到达",
  client_cancelled: "客户端断开/取消",
  key_rejected: "Key 不可用",
  model_not_allowed: "模型未授权",
  object_unavailable: "对象未知或不属于当前主体",
  object_ambiguous: "对象归属不唯一",
  local_capacity: "本地限额或容量",
  account_unavailable: "账号暂不可用",
  storage_unavailable: "账本存储不可用",
  invalid_request: "请求无效",
  indeterminate: "执行结果未明",
};
const modes: Record<string, string> = {
  generation: "生成",
  warmup: "预热",
  compact: "压缩",
};
const states: Record<string, string> = {
  intent: "在途",
  unknown: "用量未结",
  settled: "用量已结",
};
const outcomes: Record<string, string> = {
  succeeded: "成功返回",
  failed: "失败",
  cancelled: "取消",
};
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
              用量未结 {item.unresolved}
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
    setDraft((previous) => ({ ...previous, [name]: value }));
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
    <section className="panel usage-panel" aria-labelledby="usage-heading">
      <h2
        id="usage-heading"
        ref={heading}
        className={initialFilters ? "visually-hidden" : undefined}
      >
        用量与请求诊断
      </h2>
      <details className="usage-method">
        <summary>统计口径</summary>
        <p className="field-hint">
          按准入 UTC 时间统计，起止日均包含。轮换保留原 Key
          历史；迟到用量会更新原时段。每次查询为新的账本快照。
        </p>
      </details>
      <form className="usage-filters" onSubmit={submit}>
        <label>
          起始日（UTC）
          <input
            type="date"
            value={draft.start}
            disabled={busy}
            required
            onChange={(event) => update("start", event.target.value)}
          />
        </label>
        <label>
          结束日（UTC）
          <input
            type="date"
            value={draft.end}
            disabled={busy}
            required
            onChange={(event) => update("end", event.target.value)}
          />
        </label>
        <label>
          Key 标识
          <input
            list="usage-key-options"
            value={draft.key}
            maxLength={256}
            placeholder="全部 Key"
            disabled={busy}
            onChange={(event) => update("key", event.target.value)}
          />
          <datalist id="usage-key-options">
            {options.keys.map((key) => (
              <option key={key} value={key} />
            ))}
          </datalist>
        </label>
        <label>
          模型
          <input
            list="usage-model-options"
            value={draft.model}
            maxLength={128}
            placeholder="全部模型，可输入历史模型"
            disabled={busy}
            onChange={(event) => update("model", event.target.value)}
          />
          <datalist id="usage-model-options">
            {options.models.map((model) => (
              <option key={model} value={model} />
            ))}
          </datalist>
        </label>
        <label>
          执行模式
          <select
            value={draft.mode}
            disabled={busy}
            onChange={(event) => update("mode", event.target.value)}
          >
            <option value="">全部模式</option>
            {Object.entries(modes).map(([id, title]) => (
              <option key={id} value={id}>
                {title}
              </option>
            ))}
          </select>
        </label>
        <label>
          错误分类
          <select
            value={draft.failure}
            disabled={busy}
            onChange={(event) => update("failure", event.target.value)}
          >
            <option value="">全部分类</option>
            {options.failures.map((code) => (
              <option key={code} value={code}>
                {failures[code] ?? "其他异常"}
              </option>
            ))}
          </select>
        </label>
        <label>
          用量状态
          <select
            value={draft.state}
            disabled={busy}
            onChange={(event) => update("state", event.target.value)}
          >
            <option value="">全部状态</option>
            {Object.entries(states).map(([id, title]) => (
              <option key={id} value={id}>
                {title}
              </option>
            ))}
          </select>
        </label>
        <div className="usage-submit">
          <label>
            <input
              type="checkbox"
              checked={draft.failedOnly}
              disabled={busy}
              onChange={(event) => update("failedOnly", event.target.checked)}
            />
            仅异常结果
          </label>
          <button disabled={busy}>{busy ? "正在查询…" : "查询用量"}</button>
        </div>
      </form>
      {error && (
        <p role="alert" className="error-banner">
          {error}
        </p>
      )}
      {report && (
        <div aria-busy={busy} className={stale ? "usage-stale" : undefined}>
          <p className="field-hint">
            当前结果：{applied?.start} 至 {applied?.end}（UTC） ·{" "}
            {applied?.key || "全部 Key"}
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
              <span>已准入执行</span>
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
              <span>区间用量未结</span>
              <strong>
                {(
                  report.totals.inFlight + report.totals.unknown
                ).toLocaleString()}
              </strong>
              <small>
                {report.totals.inFlight} 在途 · {report.totals.unknown} unknown
              </small>
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
              [
                ["inputTokens", "输入 token"],
                ["outputTokens", "输出 token"],
                ["cachedTokens", "缓存 token"],
                ["images", "图片"],
                ["imageInputTokens", "图片工具输入 token"],
                ["imageOutputTokens", "图片工具输出 token"],
                ["estimatedMicros", "估算费用（微单位）"],
              ] as const
            ).map(([field, title]) => (
              <div key={field}>
                <span>{title}</span>
                <strong>
                  {report.totals.admitted === 0
                    ? "—"
                    : number(report.totals.metrics[field], incomplete)}
                </strong>
              </div>
            ))}
          </div>
          <p className="field-hint">
            {incomplete
              ? "含不完整/缺失证据：数值只表示已观测下界，未知部分无法量化，不能当零。"
              : "费用按部署价格估算，不是订阅余额、实际账单或绝对消耗上界。"}{" "}
            图片工具 token 与宿主响应 token
            分别统计，不相加；缺失工具证据显示不可用。
          </p>
          <KeyLimitsSummary
            key={applied?.key ?? ""}
            keyID={applied?.key ?? ""}
            refresh={policyRead}
          />
          <p className="governance-note">
            {report.lifetimeGovernance.keyID ? "当前 Key" : "全部 Key"}
            全时间治理暴露（不受其他筛选影响）：
            {report.lifetimeGovernance.inFlight} 在途、
            {report.lifetimeGovernance.unknown} unknown，保留{" "}
            {number(report.lifetimeGovernance.exposureMicros)}{" "}
            微单位。运营预留不是未知实际费用上界，时间区间改变不会释放它。
          </p>
          {report.totals.historicalWithoutTime > 0 && (
            <p className="warning-banner">
              另有 {report.totals.historicalWithoutTime}{" "}
              条符合其他筛选的历史执行缺少精确准入时间，未纳入本区间；它们仍可能占用全时间治理暴露。
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
              <table className="usage-table">
                <thead>
                  <tr>
                    <th>准入/记录时间</th>
                    <th>Key / 模型</th>
                    <th>归属 / 模式</th>
                    <th>请求结果</th>
                    <th>用量</th>
                  </tr>
                </thead>
                <tbody>
                  {report.rows.map((row) => (
                    <tr key={row.kind + row.id}>
                      <td>
                        {utc(row.atUnixSeconds)}
                        <small
                          className="key-id"
                          title={row.requestID ?? row.id}
                        >
                          {row.requestID ?? row.id}
                        </small>
                      </td>
                      <td>
                        {row.keyID}
                        <small>{row.model ?? "模型未记录"}</small>
                      </td>
                      <td>
                        {row.accountID ?? "未派发"}
                        <small>{modes[row.mode]}</small>
                      </td>
                      <td>
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
                      <td>
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
                            <small>
                              估算{" "}
                              {number(
                                row.metrics.estimatedMicros,
                                row.completeness === "partial",
                              )}{" "}
                              微单位
                            </small>
                          </>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div className="usage-pagination">
            <span>第 {page + 1} 页</span>
            <button
              className="secondary"
              disabled={busy || stale || !applied || page === 0}
              onClick={() => {
                if (applied) void load(applied, history, page - 1);
              }}
            >
              上一页
            </button>
            <button
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
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
