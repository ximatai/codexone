import { useId, useState } from "react";
import { Button, Group, SegmentedControl, Skeleton, Text } from "@mantine/core";
import { IconChevronDown, IconChevronUp } from "@tabler/icons-react";
import { useQuery } from "@tanstack/react-query";
import { request } from "../../shared/management";
import { localTime } from "../../shared/presentation";
import { z } from "../../shared/schema";
import { ErrorState } from "../../shared/ui/States";
import styles from "./accounts.module.css";

const timestamp = z.number().int().positive().max(1_000_000_000_000);
const creditSample = z.object({
  at: timestamp,
  balance: z.string().regex(/^[0-9]{1,18}(?:\.[0-9]{1,18})?$/),
});
const creditHistory = z
  .object({
    from: timestamp,
    through: timestamp,
    segments: z.array(z.array(creditSample).min(1).max(2017)).max(2017),
  })
  .refine(({ from, through, segments }) => {
    const points = segments.flat();
    return (
      through >= from &&
      through - from <= 604_800 &&
      points.length <= 2017 &&
      points.every(
        ({ at }, index) =>
          at >= from && at <= through && (!index || at > points[index - 1].at),
      )
    );
  });
type History = z.infer<typeof creditHistory>;
type CreditSample = z.infer<typeof creditSample>;
type Range = "24h" | "7d";

const integerBalance = (value: string) => BigInt(value.split(".")[0]);
const displayBalance = (value: string) =>
  integerBalance(value).toLocaleString("zh-CN");

function BalanceChart({ history }: { history: History }) {
  const [selected, setSelected] = useState<number | null>(null);
  const points = history.segments.flat();
  const active = selected === null ? undefined : points[selected];
  const balances = points.map(({ balance }) => integerBalance(balance));
  const [minimum, maximum] = balances.reduce(
    ([low, high], value) => [
      value < low ? value : low,
      value > high ? value : high,
    ],
    [balances[0], balances[0]],
  );
  const padding = (maximum - minimum) / 10n + 1n;
  const low = minimum >= padding ? minimum - padding : 0n;
  const high = maximum + padding;
  const step = (high - low + 2n) / 3n;
  const span = step * 3n;
  const ticks = [0n, 1n, 2n, 3n].map((index) => low + step * index);
  const width = 480;
  const right = width - 8;
  const left = Math.max(62, ticks[3].toLocaleString("zh-CN").length * 6 + 10);
  const top = 12;
  const bottom = 118;
  const x = (at: number) =>
    left +
    ((at - history.from) / Math.max(1, history.through - history.from)) *
      (right - left);
  const y = (value: bigint) =>
    bottom - (Number(value - low) / Number(span)) * (bottom - top);
  const pointY = ({ balance }: CreditSample) => y(integerBalance(balance));
  const timeFormat = new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
  const timeTicks = [
    history.from,
    Math.round((history.from + history.through) / 2),
    history.through,
  ];
  return (
    <>
      <svg
        className={styles.creditChart}
        viewBox="0 0 480 149"
        role="img"
        aria-label="额外使用积分余额阶梯图"
        tabIndex={0}
        onPointerMove={(event) => {
          const bounds = event.currentTarget.getBoundingClientRect();
          const position =
            ((event.clientX - bounds.left) / bounds.width) * width;
          let nearest = 0;
          for (let i = 1; i < points.length; i++) {
            if (
              Math.abs(x(points[i].at) - position) <
              Math.abs(x(points[nearest].at) - position)
            )
              nearest = i;
          }
          setSelected(
            Math.abs(x(points[nearest].at) - position) <= 12 ? nearest : null,
          );
        }}
        onPointerLeave={() => setSelected(null)}
        onBlur={() => setSelected(null)}
        onKeyDown={(event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
          event.preventDefault();
          const index =
            selected ?? (event.key === "ArrowLeft" ? points.length : -1);
          setSelected(
            Math.min(
              points.length - 1,
              Math.max(0, index + (event.key === "ArrowLeft" ? -1 : 1)),
            ),
          );
        }}
      >
        {ticks.map((value) => (
          <g key={value.toString()}>
            <line x1={left} x2={right} y1={y(value)} y2={y(value)} />
            <text x={left - 8} y={y(value) + 4} textAnchor="end">
              {value.toLocaleString("zh-CN")}
            </text>
          </g>
        ))}
        {history.segments.map((segment) => {
          const first = segment[0];
          if (segment.length === 1)
            return (
              <circle
                key={first.at}
                cx={x(first.at)}
                cy={pointY(first)}
                r={3}
              />
            );
          const line = `M${x(first.at)} ${pointY(first)}${segment
            .slice(1)
            .map((point) => `H${x(point.at)}V${pointY(point)}`)
            .join("")}`;
          return (
            <g key={first.at}>
              <path
                aria-hidden="true"
                className={styles.creditChartFill}
                d={`${line}V${bottom}H${x(first.at)}Z`}
              />
              <path className={styles.creditChartLine} d={line} />
            </g>
          );
        })}
        {timeTicks.map((at, index) => (
          <text
            key={index}
            x={x(at)}
            y={140}
            textAnchor={index === 0 ? "start" : index === 1 ? "middle" : "end"}
          >
            {timeFormat.format(at * 1000)}
          </text>
        ))}
        {active && <circle cx={x(active.at)} cy={pointY(active)} r={4} />}
      </svg>
      <Text
        size="xs"
        c="dimmed"
        className={styles.creditChartReading}
        aria-live="polite"
      >
        {active
          ? `${localTime(active.at)} · ${displayBalance(active.balance)}`
          : "\u00a0"}
      </Text>
    </>
  );
}

function CreditHistoryPanel({
  accountID,
  observedAt,
  id,
}: {
  accountID: string;
  observedAt: number | null;
  id: string;
}) {
  const [range, setRange] = useState<Range>("24h");
  const history = useQuery({
    queryKey: ["usage-credit-history", accountID, range, observedAt],
    queryFn: async ({ signal }) =>
      creditHistory.parse(
        await request(
          `/api/accounts/${encodeURIComponent(accountID)}/usage-credit-history?range=${range}`,
          { signal },
        ),
      ),
  });
  return (
    <section id={id} aria-label="积分余额走势" className={styles.creditTrend}>
      <Group justify="space-between" gap="xs">
        <Text size="sm" fw={600}>
          积分余额走势
        </Text>
        <SegmentedControl
          aria-label="积分走势时段"
          size="xs"
          value={range}
          onChange={(value) => setRange(value === "7d" ? "7d" : "24h")}
          data={[
            { label: "近 24 小时", value: "24h" },
            { label: "近 7 天", value: "7d" },
          ]}
        />
      </Group>
      {history.isPending ? (
        <Skeleton height={100} role="status" aria-label="正在读取积分走势" />
      ) : history.isError ? (
        <ErrorState
          retry={() => void history.refetch()}
          retryLabel="重试积分走势"
        >
          积分走势读取失败。
        </ErrorState>
      ) : history.data.segments.length ? (
        <BalanceChart key={range} history={history.data} />
      ) : (
        <Text size="sm" c="dimmed">
          暂无积分余额记录
        </Text>
      )}
    </section>
  );
}

export function CreditBalance({
  accountID,
  balance,
  observedAt,
  stale,
}: {
  accountID: string;
  balance: string | undefined;
  observedAt: number | null;
  stale: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const id = useId();
  return (
    <>
      <Group justify="space-between" gap="xs">
        <Text size="sm">额外使用积分</Text>
        <Group gap="xs">
          <Text size="sm" fw={600}>
            {balance === undefined
              ? "上游未提供"
              : balance === "unlimited"
                ? "不限额"
                : displayBalance(balance)}
            {balance !== undefined && stale ? "（上次读数）" : ""}
          </Text>
          <Button
            size="compact-xs"
            variant={expanded ? "light" : "subtle"}
            aria-expanded={expanded}
            aria-controls={expanded ? id : undefined}
            rightSection={
              expanded ? (
                <IconChevronUp size={13} />
              ) : (
                <IconChevronDown size={13} />
              )
            }
            onClick={() => setExpanded(!expanded)}
          >
            走势
          </Button>
        </Group>
      </Group>
      {expanded && (
        <CreditHistoryPanel
          id={id}
          accountID={accountID}
          observedAt={observedAt}
        />
      )}
    </>
  );
}
