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

function usedPercent(available: unknown, total: unknown) {
  if (
    typeof available !== "number" ||
    typeof total !== "number" ||
    !Number.isFinite(total) ||
    total <= 0 ||
    !(available >= 0 && available <= total)
  )
    return undefined;
  return ((total - available) / total) * 100;
}

function remainingSpace(bytes: unknown) {
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0)
    return undefined;
  return bytes < GiB
    ? `剩余 ${(bytes / MiB).toFixed(1)} MiB`
    : `剩余 ${(bytes / GiB).toFixed(1)} GiB`;
}

type TrendSample = ResourceSample & {
  memoryUsedPercent?: number;
  diskUsedPercent?: number;
};

function ResourceTrend({
  samples,
  label,
  field,
  scale,
}: {
  samples: TrendSample[];
  label: string;
  field:
    | "hostCPUPercent"
    | "memoryUsedPercent"
    | "diskUsedPercent"
    | "processResidentBytes";
  scale?: number;
}) {
  const [hoverTime, setHoverTime] = useState<number | null>(null);
  const latest = samples.at(-1);
  const end = latest?.unixSeconds ?? 0;
  const currentValue = latest?.[field];
  const percent = field !== "processResidentBytes";
  const readout =
    currentValue == null ? "未知" : formatResourceValue(currentValue, percent);
  const maximum =
    scale ?? Math.max(1, ...samples.map((sample) => sample[field] ?? 0)) * 1.25;
  const xAt = (time: number) => (time - end + 3600) / 36;
  const yAt = (value: number) => 29 - (Math.min(value, maximum) / maximum) * 28;
  let nearest: TrendSample | undefined;
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
  let previous: TrendSample | undefined;
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
        <Text size="xs" fw={500} ta="start">
          {label}
        </Text>
        <Text size="xs" c="dimmed" className={styles.resourceTrendValue}>
          {/* Keep the readout box fixed and replace its right-aligned text as a unit. */}
          <span key={readout}>{readout}</span>
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
  const reading = percent == null ? "未知" : `${percent.toFixed(0)}%`;
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
          <span key={percent == null ? "unknown" : reading.length}>
            {reading}
          </span>
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
  const disk = storage?.availableBytes;
  const volume = storage?.volumeTotalBytes;
  const samples = (storage?.resources ?? []).map((sample) => ({
    ...sample,
    memoryUsedPercent: usedPercent(
      sample.hostAvailableBytes,
      sample.hostTotalBytes,
    ),
    diskUsedPercent: usedPercent(sample.diskAvailableBytes, volume),
  }));
  const latest = samples.at(-1);
  const cpu = latest?.hostCPUPercent;
  return (
    <Paper withBorder p="md">
      <Stack gap="xs">
        <Title order={3} size="h5">
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
            detail={cpu == null ? undefined : `剩余 ${(100 - cpu).toFixed(0)}%`}
          />
          <ResourceGauge
            label="内存使用率"
            percent={latest?.memoryUsedPercent ?? null}
            detail={remainingSpace(latest?.hostAvailableBytes)}
          />
          <ResourceGauge
            label="数据盘使用率"
            percent={usedPercent(disk, volume) ?? null}
            detail={remainingSpace(disk)}
          />
        </div>
        <div className={styles.resourceHistory}>
          <ResourceTrend
            samples={samples}
            label="CPU 使用率"
            field="hostCPUPercent"
            scale={100}
          />
          <ResourceTrend
            samples={samples}
            label="内存使用率"
            field="memoryUsedPercent"
            scale={100}
          />
          {samples.some((sample) => sample.diskAvailableBytes != null) && (
            <ResourceTrend
              samples={samples}
              label="数据盘使用率"
              field="diskUsedPercent"
              scale={100}
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
