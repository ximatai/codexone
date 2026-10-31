import { useState } from "react";
import { Alert, Stack, Text, TextInput, Group, Button } from "@mantine/core";
import * as api from "./api";
import { TimeText } from "../../shared/ui/TimeText";
import { KeyName } from "../../shared/KeyName";
export function ExpirationEditor({
  entry,
  disabled,
  save,
}: {
  entry: api.ManagedKey;
  disabled: boolean;
  save: (expires: number | null) => Promise<boolean>;
}) {
  const originalDate =
    entry.expiresAtUnixSeconds == null
      ? ""
      : new Date(entry.expiresAtUnixSeconds * 1000).toISOString().slice(0, 10);
  const [date, setDate] = useState(originalDate);
  const epoch =
    date === originalDate && entry.expiresAtUnixSeconds != null
      ? entry.expiresAtUnixSeconds
      : date
        ? Date.parse(date + "T00:00:00Z") / 1000
        : NaN;
  const valid =
    Number.isSafeInteger(epoch) && epoch > 0 && epoch <= 1_000_000_000_000;
  return (
    <Stack>
      <Text className="wrap-anywhere">
        <KeyName {...entry} />
      </Text>
      <Text size="sm">
        当前到期：
        {entry.expiresAtUnixSeconds == null ? (
          "永不过期"
        ) : (
          <TimeText value={entry.expiresAtUnixSeconds} mode="utc" />
        )}
      </Text>
      <TextInput
        label="到期日期（UTC）"
        type="date"
        value={date}
        disabled={disabled}
        onChange={(event) => setDate(event.currentTarget.value)}
        description="日期未修改时保留原到期时刻；修改日期后从该日 UTC 00:00 起失效（快捷项至少保留整 N 天），已派发请求继续。"
      />
      <Group>
        {[30, 90].map((days) => (
          <Button
            key={days}
            variant="light"
            disabled={disabled}
            onClick={() =>
              setDate(
                new Date(Date.now() + (days + 1) * 86400000)
                  .toISOString()
                  .slice(0, 10),
              )
            }
          >
            +{days} 天
          </Button>
        ))}
      </Group>
      {valid && date !== originalDate && (
        <Text size="sm">
          到期变更：
          {entry.expiresAtUnixSeconds == null ? (
            "永不过期"
          ) : (
            <TimeText value={entry.expiresAtUnixSeconds} mode="utc" />
          )}{" "}
          → <TimeText value={epoch} mode="utc" />
        </Text>
      )}
      {valid && epoch <= Date.now() / 1000 && (
        <Alert color="yellow">所选时间已过去，保存后立即拒绝新请求。</Alert>
      )}
      <Group justify="flex-end">
        <Button
          variant="default"
          disabled={disabled || entry.expiresAtUnixSeconds == null}
          onClick={() => void save(null)}
        >
          清除到期时间
        </Button>
        <Button disabled={disabled || !valid} onClick={() => void save(epoch)}>
          保存到期时间
        </Button>
      </Group>
    </Stack>
  );
}
