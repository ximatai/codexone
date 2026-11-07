import { Anchor, Group, Paper, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";
import styles from "./overview.module.css";
import type { parseStorage, ResourceSample } from "./storage-api";

const MiB = 1024 ** 2;
const GiB = 1024 ** 3;

function ResourceTrend({
  samples,
  label,
  field,
  scale,
  detail,
}: {
  samples: ResourceSample[];
  label: string;
  field: "hostCPUPercent" | "hostAvailableBytes" | "processResidentBytes";
  scale?: number;
  detail?: string;
}) {
  const latest = samples.at(-1);
  const maximum =
    scale ?? Math.max(1, ...samples.map((sample) => sample[field] ?? 0));
  let previous: ResourceSample | undefined;
  const path = samples
    .map((sample) => {
      const value = sample[field];
      const connected =
        previous && sample.unixSeconds - previous.unixSeconds <= 60;
      previous = value == null ? undefined : sample;
      if (value == null || !latest) return "";
      const x = (sample.unixSeconds - latest.unixSeconds + 3600) / 36;
      const y = 29 - (Math.min(value, maximum) / maximum) * 28;
      return `${connected ? "L" : "M"}${x},${y}`;
    })
    .join(" ");
  return (
    <div>
      <Group justify="space-between" gap="xs">
        <Text size="xs" fw={500}>
          {label}
        </Text>
        {detail && (
          <Text size="xs" c="dimmed">
            {detail}
          </Text>
        )}
      </Group>
      <svg
        viewBox="0 0 100 30"
        width="100%"
        height="28"
        preserveAspectRatio="none"
        role={path.includes("L") ? "img" : undefined}
        aria-hidden={!path.includes("L")}
        aria-label={`${label}最近一小时趋势`}
      >
        <path
          d={path}
          fill="none"
          stroke="var(--mantine-color-blue-6)"
          strokeWidth="1.5"
          vectorEffect="non-scaling-stroke"
        />
      </svg>
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
          运行资源
        </Title>
        {stale && (
          <Text size="xs" c="orange.8">
            快照已陈旧
          </Text>
        )}
        <div className={styles.resourceGauges}>
          <ResourceGauge label="CPU 使用率" percent={cpu ?? null} />
          <ResourceGauge
            label="服务器可用内存"
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
        <Group justify="space-between" gap="xs">
          <Anchor component={Link} to="/?storage=details" size="xs">
            数据盘详情 ›
          </Anchor>
          <Text size="xs" c="dimmed">
            {!storage
              ? "保护状态未知"
              : !storage.admissionAllowed
                ? "已暂停准入"
                : !storage.optionalWorkAllowed
                  ? "可选任务已暂停"
                  : "保护未触发"}
          </Text>
        </Group>
        <div className={styles.resourceHistory}>
          <Text size="xs" c="dimmed">
            最近一小时
          </Text>
          <ResourceTrend
            samples={samples}
            label="服务器 CPU 使用率"
            field="hostCPUPercent"
            scale={100}
          />
          <ResourceTrend
            samples={samples}
            label="服务器可用内存"
            field="hostAvailableBytes"
            scale={total}
          />
          <ResourceTrend
            samples={samples}
            label="网关内存占用"
            field="processResidentBytes"
            detail={
              latest?.processResidentBytes == null
                ? "未知"
                : `${(latest.processResidentBytes / MiB).toFixed(0)} MiB`
            }
          />
        </div>
      </Stack>
    </Paper>
  );
}
