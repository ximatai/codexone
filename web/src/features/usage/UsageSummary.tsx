import { metricLabels, money, estimateNote } from "../../shared/presentation";
import type { UsageReport, Metrics } from "./api";
import { number, duration } from "./format";
import styles from "./usage.module.css";
export function UsageSummary({ report }: { report: UsageReport }) {
  const { totals } = report;
  const incomplete = totals.partial + totals.unavailable > 0;
  const tokenTotal =
    totals.metrics.inputTokens == null || totals.metrics.outputTokens == null
      ? "不可用"
      : (incomplete ? "≥ " : "") +
        (
          BigInt(totals.metrics.inputTokens) +
          BigInt(totals.metrics.outputTokens)
        ).toLocaleString("zh-CN");
  const items = [
    ["请求", totals.admitted.toLocaleString(), "生成 / 预热 / 压缩"],
    [
      "失败 / 取消",
      `${totals.failed} / ${totals.cancelled}`,
      "结果与用量完整度独立",
    ],
    ["Token 合计", tokenTotal, "输入含缓存 + 输出；图片工具单列"],
    [
      "平均首事件耗时",
      duration(totals.averageFirstEventMilliseconds),
      "首个上游事件，非下游首 Token",
    ],
    [
      "P95 首事件耗时",
      duration(totals.p95FirstEventMilliseconds),
      "仅非空观测样本",
    ],
    ["估算费用", money(totals.metrics.estimatedMicros), "估算，非账单"],
  ];
  return (
    <div className={styles.summary}>
      {items.map(([label, value, note]) => (
        <div key={label}>
          <span>{label}</span>
          <strong>{value}</strong>
          <small>{note}</small>
        </div>
      ))}
    </div>
  );
}
export function UsageEvidence({
  report,
  expanded = false,
}: {
  report: UsageReport;
  expanded?: boolean;
}) {
  const { totals } = report;
  const incomplete = totals.partial + totals.unavailable > 0;
  return (
    <details className={styles.moreFilters} open={expanded || undefined}>
      <summary hidden={expanded}>统计明细</summary>
      <div className={styles.metrics}>
        <div>
          <span>平均总耗时</span>
          <strong>{duration(totals.averageTotalMilliseconds)}</strong>
          <small>仅非空观测样本</small>
        </div>
        <div>
          <span>已记录准入前拒绝</span>
          <strong>{totals.recordedRejections.toLocaleString()}</strong>
          <small>未启动执行</small>
        </div>
        <div>
          <span>区间待核对</span>
          <strong>{(totals.inFlight + totals.unknown).toLocaleString()}</strong>
          <small>
            {totals.inFlight} 在途 · {totals.unknown} 待核对
          </small>
        </div>
        <div>
          <span>用量完整度</span>
          <strong>{totals.complete} 完整</strong>
          <small>
            {totals.partial} 部分 · {totals.unavailable} 不可用
          </small>
        </div>
        {(Object.entries(metricLabels) as [keyof Metrics, string][]).map(
          ([field, title]) => (
            <div key={field}>
              <span>{title}</span>
              <strong>
                {totals.admitted === 0
                  ? "—"
                  : field === "estimatedMicros"
                    ? money(totals.metrics[field])
                    : number(totals.metrics[field], incomplete)}
              </strong>
            </div>
          ),
        )}
      </div>
      <p className={styles.hint}>
        {incomplete
          ? "含不完整/缺失证据：数值只表示已观测下界，未知部分无法量化，不能当零。"
          : estimateNote}{" "}
        图片工具 token 与宿主响应 token
        分别统计，不相加；缺失工具证据显示不可用。
      </p>
    </details>
  );
}
