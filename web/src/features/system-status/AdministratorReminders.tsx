import { Alert, Anchor, Paper, Stack, Title } from "@mantine/core";
import { Link } from "react-router";
import type { AttentionItem } from "./attention-api";
import type { availabilityBlocker } from "./availability-blocker";
import type { parseStorage } from "./storage-api";

export function AdministratorReminders({
  storage,
  storageError,
  backupOverdue,
  backupDisabled,
  backupSizeWarning,
  backupUnconfirmed,
  availability,
}: {
  storage?: ReturnType<typeof parseStorage>;
  storageError: boolean;
  backupOverdue?: AttentionItem;
  backupDisabled?: boolean;
  backupSizeWarning?: boolean;
  backupUnconfirmed: boolean;
  availability: ReturnType<typeof availabilityBlocker>;
}) {
  const disk =
    !storage || storage.pressure === "unknown"
      ? null
      : storage.admissionAllowed === false
        ? { text: "存储保护已暂停接收新请求。", color: "red" }
        : storage.optionalWorkAllowed === false
          ? { text: "存储保护已暂停备份和部分统计。", color: "orange" }
          : null;
  const free = storage?.availableBytes;
  const service =
    availability?.to === "/?storage=details" ? null : availability;
  const showBackupDisabled = backupDisabled && !backupUnconfirmed;
  const showBackupSize = backupSizeWarning && !backupUnconfirmed;
  if (
    !disk &&
    !service &&
    !backupOverdue &&
    !showBackupDisabled &&
    !showBackupSize
  )
    return null;

  return (
    <Paper
      withBorder
      p="md"
      component="section"
      aria-labelledby="administrator-reminders"
    >
      <Stack gap="xs">
        <Title id="administrator-reminders" order={3} size="h5">
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
        {showBackupDisabled && (
          <Alert color="orange">在线定时备份未启用。</Alert>
        )}
        {showBackupSize && (
          <Alert color="orange">
            备份占用已超过提醒阈值，请检查存储容量，并将备份和主密钥分别异地保存。
          </Alert>
        )}
      </Stack>
    </Paper>
  );
}
