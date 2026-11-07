import { Alert, Anchor, Button, Paper, Stack, Title } from "@mantine/core";
import { Link } from "react-router";
import type { AttentionItem } from "./attention-api";
import type { availabilityBlocker } from "./availability-blocker";
import type { parseStorage } from "./storage-api";

export function AdministratorReminders({
  storage,
  storageError,
  backupOverdue,
  backupUnconfirmed,
  attentionError,
  retry,
  availability,
}: {
  storage?: ReturnType<typeof parseStorage>;
  storageError: boolean;
  backupOverdue?: AttentionItem;
  backupUnconfirmed: boolean;
  attentionError: boolean;
  retry: () => void;
  availability: ReturnType<typeof availabilityBlocker>;
}) {
  const disk =
    storageError || storage?.pressure === "unknown"
      ? { text: "存储保护状态未知", color: "orange" }
      : storage?.admissionAllowed === false
        ? { text: "存储保护已暂停接收新请求。", color: "red" }
        : storage?.optionalWorkAllowed === false
          ? { text: "存储保护已暂停备份和部分统计。", color: "orange" }
          : null;
  const free = storage?.availableBytes;
  const service =
    availability?.to === "/?storage=details" ? null : availability;
  // Low-disk protection can intentionally skip the reminder query.
  const unreadable = attentionError && !disk;
  if (!disk && !service && !backupOverdue && !unreadable) return null;

  return (
    <Paper
      withBorder
      p="md"
      component="section"
      aria-labelledby="administrator-reminders"
    >
      <Stack gap="xs">
        <Title id="administrator-reminders" order={3} size="h4">
          运行提醒
        </Title>
        {disk && (
          <Alert color={disk.color}>
            {disk.text}{" "}
            {!storageError && typeof free === "number" && (
              <>数据盘可用 {(free / 1024 ** 2).toFixed(0)} MiB。 </>
            )}
            <Anchor component={Link} to="/?storage=details" size="sm">
              检查存储
            </Anchor>
          </Alert>
        )}
        {service && (
          <Alert color="orange">
            {service.text}{" "}
            <Anchor component={Link} to={service.to} size="sm">
              {service.link}
            </Anchor>
          </Alert>
        )}
        {backupOverdue && (
          <Alert
            color={
              !backupUnconfirmed && backupOverdue.severity === "critical"
                ? "red"
                : "orange"
            }
          >
            {backupUnconfirmed
              ? "上次检测到备份超时，当前待确认。"
              : "备份超时，请检查磁盘空间。"}{" "}
            <Anchor component={Link} to="/?storage=details" size="sm">
              查看备份
            </Anchor>
          </Alert>
        )}
        {unreadable && (
          <Alert color="orange">
            运行提醒读取失败{" "}
            <Button variant="subtle" size="compact-xs" onClick={retry}>
              重试
            </Button>
          </Alert>
        )}
      </Stack>
    </Paper>
  );
}
