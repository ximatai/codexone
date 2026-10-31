import { Text } from "@mantine/core";
import styles from "./KeyName.module.css";
export function KeyName({
  displayName,
  principal,
  stacked = false,
}: {
  displayName?: string | null;
  principal?: string | null;
  stacked?: boolean;
}) {
  return (
    <span className="wrap-anywhere">
      <span>{displayName ?? principal ?? "主体未记录"}</span>
      {displayName && principal && (
        <Text
          component="span"
          className={stacked ? styles.principal : undefined}
          size="xs"
          c="dimmed"
        >
          {!stacked && " · "}
          {principal}
        </Text>
      )}
    </span>
  );
}
