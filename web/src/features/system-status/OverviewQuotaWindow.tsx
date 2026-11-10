import { useQuery } from "@tanstack/react-query";
import { Tooltip, UnstyledButton } from "@mantine/core";
import { IconAlertCircle } from "@tabler/icons-react";
import { useEffect, useId, useState } from "react";
import { useReducedMotion } from "@mantine/hooks";
import { QuotaWindowBar } from "../account-management/QuotaWindowBar";
import type { QuotaWindow } from "../account-management/observation-api";
import {
  fetchQuotaTrend,
  predictQuota,
  quotaSegments,
  referenceHours,
  type QuotaHistory,
  type QuotaSample,
  type ReferenceHours,
} from "./quota-trend";
import styles from "./overview.module.css";

const transitionMs = 220;
const scenarioDescription = "阴影表示较快和较慢消耗情景之间的范围";

type Forecast = Extract<ReturnType<typeof predictQuota>, { rate: number }>;

function duration(seconds: number) {
  const minutes = Math.max(1, Math.round(seconds / 60));
  const hours = Math.floor(minutes / 60);
  return hours ? `${hours} 小时 ${minutes % 60} 分钟` : `${minutes} 分钟`;
}

function QuotaChart({
  history,
  reset,
  now,
  forecast,
  hasScenario,
}: {
  history: QuotaHistory;
  reset: number;
  now: number;
  forecast: Forecast | undefined;
  hasScenario: boolean;
}) {
  const start = Math.min(history.samples[0][0], reset - 60);
  const end = Math.max(start + 60, reset, now);
  const x = (at: number) => 30 + (290 * (at - start)) / (end - start);
  const y = (remaining: number) => 18 + ((100 - remaining) * 118) / 100;
  const path = (points: QuotaSample[]) =>
    points.map(([at, remaining]) => `${x(at)},${y(remaining)}`).join(" ");
  const scenario = (rate: number) => {
    if (!forecast) return [];
    const [at, remaining] = forecast.anchor;
    const points: QuotaSample[] = [forecast.anchor];
    const zero = rate > 0 ? at + remaining / rate : Infinity;
    if (zero < reset) points.push([zero, 0]);
    points.push([reset, Math.max(0, remaining - rate * (reset - at))]);
    return points;
  };
  const ticks = [start, (start + end) / 2, end];
  const dateOptions = { month: "numeric", day: "numeric" } as const;
  const timeOptions = { hour: "2-digit", minute: "2-digit" } as const;
  const dateFormat = new Intl.DateTimeFormat("zh-CN", dateOptions);
  const distinctDates = new Set(ticks.map((at) => dateFormat.format(at * 1000)))
    .size;
  const tickFormat =
    end - start >= 86400 && distinctDates === ticks.length
      ? dateFormat
      : new Intl.DateTimeFormat(
          "zh-CN",
          distinctDates > 1 ? { ...dateOptions, ...timeOptions } : timeOptions,
        );
  const chartLabel = [
    "剩余额度走势，实线为历史",
    forecast && "虚线为预测",
    hasScenario && scenarioDescription,
    "竖线为现在和重置",
  ]
    .filter(Boolean)
    .join("，");
  return (
    <svg
      viewBox="0 0 328 154"
      className={styles.quotaChart}
      role="img"
      aria-label={chartLabel}
    >
      {[0, 50, 100].map((value) => (
        <g key={value}>
          <text x="25" y={y(value)} textAnchor="end" dominantBaseline="middle">
            {value}%
          </text>
          <line
            className={styles.quotaGrid}
            x1="30"
            x2="320"
            y1={y(value)}
            y2={y(value)}
          />
        </g>
      ))}
      {[
        { at: now, label: "现在" },
        { at: reset, label: "重置" },
      ].map(({ at, label }) => (
        <g key={label}>
          <line
            className={styles.quotaMarker}
            x1={x(at)}
            x2={x(at)}
            y1="16"
            y2={y(0)}
          />
          {(label === "重置" || Math.abs(x(now) - x(reset)) >= 28) && (
            <text x={x(at)} y="10" textAnchor={x(at) > 300 ? "end" : "middle"}>
              {label}
            </text>
          )}
        </g>
      ))}
      {forecast && hasScenario && (
        <polygon
          className={styles.quotaScenario}
          points={path([
            ...scenario(forecast.slow),
            ...scenario(forecast.fast).reverse(),
          ])}
        />
      )}
      {quotaSegments(history.samples).map((segment) =>
        segment.length === 1 ? (
          <circle
            key={segment[0][0]}
            cx={x(segment[0][0])}
            cy={y(segment[0][1])}
            r="2"
            className={styles.quotaPoint}
          />
        ) : (
          <polyline
            key={segment[0][0]}
            className={styles.quotaHistory}
            points={path(segment)}
          />
        ),
      )}
      {forecast && (
        <polyline
          className={styles.quotaProjection}
          points={path(scenario(forecast.rate))}
        />
      )}
      {ticks.map((at, index) => (
        <text
          key={at}
          x={x(at)}
          y="151"
          textAnchor={
            index === 0
              ? "start"
              : index === ticks.length - 1
                ? "end"
                : "middle"
          }
        >
          {tickFormat.format(at * 1000)}
        </text>
      ))}
    </svg>
  );
}

function QuotaTrendDetails({
  accountID,
  kind,
  value,
  observedAt,
  unavailable,
}: {
  accountID: string;
  kind: "primary" | "secondary";
  value: QuotaWindow;
  observedAt: number | null;
  unavailable: boolean;
}) {
  const [hours, setHours] = useState<ReferenceHours>(1);
  const query = useQuery({
    queryKey: ["quota-trend", accountID, observedAt],
    queryFn: ({ signal }) => fetchQuotaTrend(accountID, signal),
    staleTime: 30_000,
    gcTime: 0,
    retry: false,
    placeholderData: (previous) => previous,
  });
  const now = Date.now() / 1000;
  const reset = value.resetsAtUnixSeconds;
  const history = query.data?.[kind];
  const usableHistory =
    history &&
    reset !== null &&
    Math.abs(reset - history.reset) <= 60 &&
    value.durationSeconds === history.duration &&
    history.samples.length > 0
      ? history
      : undefined;
  const last = usableHistory?.samples.at(-1);
  let summary = "历史数据积累中";
  let forecast: Forecast | undefined;
  let warning = false;
  let comparison: string | undefined;
  if (query.isError) summary = "额度历史读取失败";
  else if (query.isPending) summary = "加载中…";
  else if (unavailable || (reset !== null && reset <= now))
    summary = "额度待更新，预测已暂停";
  else if (value.usedPercent !== null && value.usedPercent >= 100)
    summary = "本期额度已用尽";
  else if ((value.durationSeconds ?? Infinity) < hours * 3600)
    summary = "额度周期短于所选参考时段";
  else if (
    last &&
    last[0] === observedAt &&
    last[0] <= now &&
    reset !== null &&
    value.usedPercent !== null &&
    Math.abs(last[1] - (100 - value.usedPercent)) < 0.001
  ) {
    const assessment = predictQuota(usableHistory!.samples, hours);
    if (assessment.state === "ready" || assessment.state === "coarse") {
      forecast = assessment;
      const exhaustion = last[0] + last[1] / assessment.rate;
      const prefix = assessment.state === "coarse" ? "粗估" : "预计";
      warning = exhaustion < reset;
      summary = warning
        ? `${prefix}约 ${duration(exhaustion - now)}后耗尽`
        : `${prefix}可用到本次重置`;
      if (warning) comparison = `比重置早 ${duration(reset - exhaustion)}`;
      if (exhaustion <= now) {
        summary = `${prefix}可能已耗尽`;
        comparison = "等待新读数";
      }
    } else {
      summary =
        assessment.state === "coverage"
          ? "有效采样覆盖不足，暂不预测"
          : "近期额度变化太少，暂不预测";
    }
  }
  const hasScenario = forecast !== undefined && forecast.slow < forecast.fast;
  return (
    <div className={styles.quotaTrendPanel}>
      <div className={styles.quotaTrendRow}>
        <strong>剩余额度趋势</strong>
        <div className={styles.quotaLegend}>
          <span aria-hidden={!usableHistory}>
            <i className={styles.quotaLegendHistory} />
            历史
          </span>
          <Tooltip
            label={scenarioDescription}
            disabled={!hasScenario}
            events={{ hover: true, focus: true, touch: true }}
            multiline
            maw={220}
          >
            <span
              aria-hidden={!forecast}
              tabIndex={hasScenario ? 0 : undefined}
            >
              <i className={styles.quotaLegendProjection} />
              预测
            </span>
          </Tooltip>
        </div>
      </div>
      <div className={styles.quotaTrendRow}>
        <span className={styles.quotaTrendLabel}>参考时段</span>
        <div
          className={styles.quotaReferences}
          role="group"
          aria-label="预测参考时段"
        >
          {referenceHours.map((window) => (
            <UnstyledButton
              key={window}
              className={styles.quotaReference}
              aria-pressed={hours === window}
              onClick={() => setHours(window)}
            >
              {window} 小时
            </UnstyledButton>
          ))}
        </div>
      </div>
      {usableHistory && reset !== null && (
        <QuotaChart
          history={usableHistory}
          reset={reset}
          now={now}
          forecast={forecast}
          hasScenario={hasScenario}
        />
      )}
      <div
        className={styles.quotaAssessment}
        data-warning={warning || undefined}
        aria-live="polite"
      >
        {warning && <IconAlertCircle size={14} aria-hidden="true" />}
        <div className={styles.quotaAssessmentText}>
          <span className={styles.quotaAssessmentSummary}>{summary}</span>
          {comparison && (
            <span className={styles.quotaAssessmentComparison}>
              {comparison}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

export function OverviewQuotaWindow(props: {
  accountID: string;
  kind: "primary" | "secondary";
  title: string;
  value: QuotaWindow;
  observedAt: number | null;
  unavailable: boolean;
}) {
  const id = useId();
  const reducedMotion = useReducedMotion();
  const [expanded, setExpanded] = useState(false);
  const [retainContent, setRetainContent] = useState(false);
  useEffect(() => {
    if (expanded || !retainContent) return;
    const timer = window.setTimeout(
      () => setRetainContent(false),
      reducedMotion ? 0 : transitionMs,
    );
    return () => window.clearTimeout(timer);
  }, [expanded, reducedMotion, retainContent]);

  const canExpand = props.value.usedPercent !== null;
  return (
    <QuotaWindowBar
      showUsed
      title={props.title}
      value={props.value}
      trend={
        canExpand
          ? {
              expanded,
              controls: id,
              stale: props.unavailable,
              toggle: () => {
                setRetainContent(true);
                setExpanded((open) => !open);
              },
              details: (
                <div id={id}>
                  <div
                    className={styles.quotaTrendMotion}
                    data-expanded={expanded}
                    aria-hidden={!expanded}
                    inert={!expanded}
                    style={{
                      transitionDuration: reducedMotion
                        ? "0ms"
                        : `${transitionMs}ms`,
                    }}
                  >
                    <div className={styles.quotaTrendClip}>
                      {(expanded || (retainContent && !reducedMotion)) && (
                        <div className={styles.quotaTrendInset}>
                          <QuotaTrendDetails {...props} />
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              ),
            }
          : undefined
      }
    />
  );
}
