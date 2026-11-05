import { UsageDisclosure } from "./UsageDisclosure";
import { Tooltip } from "@mantine/core";
import { metricLabels, money, estimateNote } from "../../shared/presentation";
import type { UsageReport, Metrics } from "./api";
import { failures } from "../../shared/presentation";
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
  ];
  return (
    <div className={styles.summary}>
      {items.map(([label, value, note]) => (
        <div key={label}>
          <Tooltip label={note} multiline maw={280} withArrow>
            <span tabIndex={0}>{label}</span>
          </Tooltip>
          <strong>{value}</strong>
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
    <EvidenceContainer expanded={expanded}>
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
          <span>用量未知</span>
          <strong>{totals.usageUnknown ?? totals.unknown} 条</strong>
          <small>
            {Object.entries(totals.unknownReasons ?? {})
              .map(
                ([reason, count]) =>
                  `${failures[reason] ?? "原因未提供"} ${count} 条`,
              )
              .join(" · ") || "原因未提供"}
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
                    ? `${(totals.metrics.priceCompleteness ?? (incomplete ? "partial" : "complete")) !== "complete" && totals.metrics[field] != null ? "≥ " : ""}${money(totals.metrics[field])}`
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
        明细仅保留最近 90 天；更早执行保留 UTC 日汇总，按同名业务日期展示，超过
        90 天的数据日界近似、总量保留。待核对满 24 小时自动关闭，用量仍为未知。
        图片工具 token 与宿主响应 token 分别统计；SVG
        作者输入与输出额外计入每日额度，作者推理不重复累计。缺失工具证据显示不可用。
      </p>
    </EvidenceContainer>
  );
}

function EvidenceContainer({
  expanded,
  children,
}: {
  expanded: boolean;
  children: React.ReactNode;
}) {
  return expanded ? (
    <div>{children}</div>
  ) : (
    <UsageDisclosure title="统计明细" className={styles.moreFilters}>
      {children}
    </UsageDisclosure>
  );
}
