import { Group, Paper, Stack, Text, Title } from "@mantine/core";
import { useState } from "react";
import styles from "./overview.module.css";
import type { parseStorage, ResourceSample } from "./storage-api";

const MiB = 1024 ** 2;
const GiB = 1024 ** 3;
const sampleTime = new Intl.DateTimeFormat("zh-CN", {
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

function formatResourceValue(value: number, percent: boolean) {
  if (percent) return `${value.toFixed(1)}%`;
  return value >= GiB
    ? `${(value / GiB).toFixed(2)} GiB`
    : `${(value / MiB).toFixed(1)} MiB`;
}

function ResourceTrend({
  samples,
  label,
  field,
  scale,
}: {
  samples: ResourceSample[];
  label: string;
  field:
    | "hostCPUPercent"
    | "hostAvailableBytes"
    | "diskAvailableBytes"
    | "processResidentBytes";
  scale?: number;
}) {
  const [hoverTime, setHoverTime] = useState<number | null>(null);
  const latest = samples.at(-1);
  const end = latest?.unixSeconds ?? 0;
  const currentValue = latest?.[field];
  const percent = field === "hostCPUPercent";
  const maximum =
    scale ?? Math.max(1, ...samples.map((sample) => sample[field] ?? 0)) * 1.25;
  const xAt = (time: number) => (time - end + 3600) / 36;
  const yAt = (value: number) => 29 - (Math.min(value, maximum) / maximum) * 28;
  let nearest: ResourceSample | undefined;
  if (hoverTime != null) {
    for (const sample of samples) {
      const distance = Math.abs(sample.unixSeconds - hoverTime);
      if (
        distance <= 30 &&
        (!nearest || distance < Math.abs(nearest.unixSeconds - hoverTime))
      )
        nearest = sample;
    }
  }
  const activeValue = nearest?.[field];
  const hasSamples = samples.some((sample) => sample[field] != null);
  let previous: ResourceSample | undefined;
  const path = samples
    .map((sample) => {
      const value = sample[field];
      const connected =
        previous && sample.unixSeconds - previous.unixSeconds <= 60;
      previous = value == null ? undefined : sample;
      if (value == null) return "";
      return `${connected ? "L" : "M"}${xAt(sample.unixSeconds)},${yAt(value)}`;
    })
    .join(" ");
  return (
    <div>
      <Group justify="space-between" gap="xs">
        <Text size="xs" fw={500}>
          {label}
        </Text>
        <Text size="xs" c="dimmed" className={styles.resourceTrendValue}>
          {currentValue == null
            ? "未知"
            : formatResourceValue(currentValue, percent)}
        </Text>
      </Group>
      <div className={styles.resourceTrendPlot}>
        <svg
          viewBox="0 0 100 30"
          width="100%"
          height="28"
          preserveAspectRatio="none"
          role={hasSamples ? "img" : undefined}
          aria-hidden={!hasSamples}
          aria-label={`${label}最近一小时趋势`}
          onPointerMove={(event) => {
            if (!hasSamples) return;
            const bounds = event.currentTarget.getBoundingClientRect();
            if (bounds.width > 0)
              setHoverTime(
                end -
                  3600 +
                  ((event.clientX - bounds.left) / bounds.width) * 3600,
              );
          }}
          onPointerLeave={() => setHoverTime(null)}
          onPointerCancel={() => setHoverTime(null)}
        >
          <path
            d={path}
            fill="none"
            stroke="var(--mantine-color-blue-6)"
            strokeWidth="1.5"
            vectorEffect="non-scaling-stroke"
          />
          {nearest && activeValue != null && (
            <line
              x1={xAt(nearest.unixSeconds)}
              x2={xAt(nearest.unixSeconds)}
              y1="0"
              y2="30"
              stroke="var(--mantine-color-blue-6)"
              strokeDasharray="3 2"
              vectorEffect="non-scaling-stroke"
            />
          )}
        </svg>
        {nearest && (
          <Paper
            withBorder
            p="xs"
            shadow="sm"
            role="tooltip"
            className={styles.resourceTrendTooltip}
            data-side={xAt(nearest.unixSeconds) > 50 ? "left" : "right"}
          >
            <Text size="xs" c="dimmed">
              {sampleTime.format(nearest.unixSeconds * 1000)}
            </Text>
            <Text size="sm" fw={600}>
              {activeValue == null
                ? "未采样"
                : formatResourceValue(activeValue, percent)}
            </Text>
          </Paper>
        )}
      </div>
    </div>
  );
}

function ResourceGauge({
  label,
  percent,
  detail,
}: {
  label: string;
  percent: number | null;
  detail?: string;
}) {
  return (
    <div className={styles.resourceGauge} role="group" aria-label={label}>
      <Text size="xs">{label}</Text>
      <div className={styles.gaugeDial}>
        <svg viewBox="0 0 72 72" aria-hidden="true">
          <circle cx="36" cy="36" r="30" className={styles.gaugeTrack} />
          {percent != null && percent > 0 && (
            <circle
              cx="36"
              cy="36"
              r="30"
              pathLength="100"
              strokeDasharray={`${percent} 100`}
              transform="rotate(-90 36 36)"
              className={styles.gaugeFill}
            />
          )}
        </svg>
        <Text className={styles.gaugeValue} fw={650} size="sm">
          {percent == null ? "未知" : `${percent.toFixed(0)}%`}
        </Text>
      </div>
      {detail && (
        <Text size="xs" c="dimmed">
          {detail}
        </Text>
      )}
    </div>
  );
}

export function RuntimeResources({
  storage,
  stale,
}: {
  storage?: ReturnType<typeof parseStorage>;
  stale: boolean;
}) {
  const samples = storage?.resources ?? [];
  const latest = samples.at(-1);
  const total = latest?.hostTotalBytes;
  const available = latest?.hostAvailableBytes;
  const cpu = latest?.hostCPUPercent;
  const load = latest?.hostLoadAverage1m;
  const memoryPercent =
    available != null && total && available <= total
      ? (available / total) * 100
      : null;
  const disk = storage?.availableBytes;
  const volume = storage?.volumeTotalBytes;
  const diskFree =
    typeof disk === "number" &&
    typeof volume === "number" &&
    volume > 0 &&
    disk >= 0 &&
    disk <= volume
      ? (disk / volume) * 100
      : null;
  return (
    <Paper withBorder p="md">
      <Stack gap="xs">
        <Title order={3} size="h4">
          服务器运行资源
        </Title>
        {stale && (
          <Text size="xs" c="orange.8">
            快照已陈旧
          </Text>
        )}
        <div className={styles.resourceGauges}>
          <ResourceGauge
            label="CPU 使用率"
            percent={cpu ?? null}
            detail={load?.toFixed(2)}
          />
          <ResourceGauge
            label="可用内存"
            percent={memoryPercent}
            detail={
              available == null
                ? undefined
                : `${(available / GiB).toFixed(1)}${total ? ` / ${(total / GiB).toFixed(1)}` : ""} GiB`
            }
          />
          <ResourceGauge
            label="数据盘可用"
            percent={diskFree}
            detail={
              typeof disk === "number"
                ? disk < GiB
                  ? `${(disk / MiB).toFixed(1)} MiB`
                  : `${(disk / GiB).toFixed(1)} GiB`
                : undefined
            }
          />
        </div>
        <div className={styles.resourceHistory}>
          <Text size="xs" c="dimmed">
            最近一小时
          </Text>
          <ResourceTrend
            samples={samples}
            label="CPU 使用率"
            field="hostCPUPercent"
            scale={100}
          />
          <ResourceTrend
            samples={samples}
            label="可用内存"
            field="hostAvailableBytes"
            scale={total}
          />
          {samples.some((sample) => sample.diskAvailableBytes != null) && (
            <ResourceTrend
              samples={samples}
              label="数据盘可用"
              field="diskAvailableBytes"
              scale={
                typeof volume === "number" && volume > 0 ? volume : undefined
              }
            />
          )}
          <ResourceTrend
            samples={samples}
            label="CodexOne 内存占用"
            field="processResidentBytes"
          />
        </div>
      </Stack>
    </Paper>
  );
}
