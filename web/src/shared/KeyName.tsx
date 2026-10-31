import { Text } from "@mantine/core";
export function KeyName({
  displayName,
  principal,
}: {
  displayName?: string | null;
  principal?: string | null;
}) {
  if (!displayName) return <>{principal ?? "主体未记录"}</>;
  return (
    <span>
      {displayName ?? principal ?? "主体未记录"}
      {displayName && principal && (
        <Text component="span" size="xs" c="dimmed">
          {" "}
          · {principal}
        </Text>
      )}
    </span>
  );
}
