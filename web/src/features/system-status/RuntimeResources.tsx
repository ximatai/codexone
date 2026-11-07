import { Anchor, Paper, Progress, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";
import styles from "./overview.module.css";
import type { parseStorage, ResourceSample } from "./storage-api";

const MiB = 1024 ** 2;
const GiB = 1024 ** 3;

function Series({
  label,
  samples,
  field,
  scale,
  format,
}: {
  label: string;
  samples: ResourceSample[];
  field: "processResidentBytes" | "hostAvailableBytes" | "hostCPUPercent";
  scale?: number;
  format: (value: number) => string;
}) {
  const latest = samples.at(-1);
  const last = latest?.[field];
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
      <Text size="xs">{label}</Text>
      <Text fw={650} size="sm">
        {last == null ? "未知" : format(last)}
      </Text>
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

export function RuntimeResources({
  storage,
  stale,
}: {
  storage?: ReturnType<typeof parseStorage>;
  stale: boolean;
}) {
  const samples = storage?.resources ?? [];
  const total = samples.at(-1)?.hostTotalBytes;
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
        <Text size="xs" c={stale ? "orange.8" : "dimmed"}>
          最近一小时{stale ? " · 快照已陈旧" : ""}
        </Text>
        <div className={styles.memoryGrid}>
          <Series
            label="网关内存占用"
            field="processResidentBytes"
            samples={samples}
            format={(value) => `${(value / MiB).toFixed(0)} MiB`}
          />
          <Series
            label="服务器可用内存"
            field="hostAvailableBytes"
            samples={samples}
            scale={total}
            format={(value) =>
              `${(value / GiB).toFixed(1)}${total ? ` / ${(total / GiB).toFixed(1)}` : ""} GiB`
            }
          />
        </div>
        <Series
          label="服务器 CPU 使用率"
          field="hostCPUPercent"
          samples={samples}
          scale={100}
          format={(value) => `${value.toFixed(0)}%`}
        />
        <Anchor component={Link} to="/?storage=details" size="sm">
          数据盘
          {typeof disk === "number"
            ? disk < GiB
              ? `剩余 ${(disk / MiB).toFixed(1)} MiB`
              : `剩余 ${(disk / GiB).toFixed(1)} GiB`
            : "余量未知"}{" "}
          ›
        </Anchor>
        {diskFree != null && (
          <Progress
            aria-label="数据盘可用比例"
            value={diskFree}
            color={!storage?.optionalWorkAllowed ? "orange" : "blue"}
          />
        )}
        <Text size="xs" c="dimmed">
          {!storage
            ? "保护状态未知"
            : !storage.admissionAllowed
              ? "已暂停准入"
              : !storage.optionalWorkAllowed
                ? "可选任务已暂停"
                : "保护未触发"}
        </Text>
      </Stack>
    </Paper>
  );
}
