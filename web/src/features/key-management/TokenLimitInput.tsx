import { useState, type ReactNode } from "react";
import { Select, NumberInput } from "@mantine/core";
export function TokenLimitInput({
  value,
  disabled,
  onChange,
  error,
}: {
  value: number | null;
  disabled: boolean;
  onChange: (value: number) => void;
  error?: ReactNode;
}) {
  const [unit, setUnit] = useState(() =>
    value && value >= 1000000
      ? "1000000"
      : value && value >= 10000
        ? "10000"
        : "1",
  );
  const [draft, setDraft] = useState<string | number | undefined>();
  const scale = Number(unit);
  return (
    <NumberInput
      style={{ order: -1 }}
      label="每日 Token 上限"
      aria-label="每日 Token 上限"
      value={value === null ? "" : (draft ?? value / scale)}
      onBlur={() => setDraft(undefined)}
      disabled={disabled}
      error={error}
      min={0}
      max={1000000000000 / scale}
      hideControls
      rightSectionWidth={112}
      rightSection={
        <Select
          w={112}
          rightSectionWidth={24}
          styles={{ input: { paddingLeft: 8, paddingRight: 24 } }}
          aria-label="Token 单位"
          variant="unstyled"
          disabled={disabled}
          value={unit}
          allowDeselect={false}
          comboboxProps={{
            withinPortal: true,
            zIndex: 350,
            width: 160,
            position: "bottom-end",
          }}
          onChange={(value) => {
            setUnit(value ?? "1");
            setDraft(undefined);
          }}
          data={[
            { value: "1", label: "Token" },
            { value: "10000", label: "万 Token" },
            { value: "1000000", label: "百万 Token" },
          ]}
        />
      }
      onChange={(raw) => {
        setDraft(raw);
        const amount = raw === "" ? 0 : Number(raw) * scale;
        const rounded = Math.round(amount);
        onChange(Math.abs(amount - rounded) < 0.000001 ? rounded : amount);
      }}
    />
  );
}
