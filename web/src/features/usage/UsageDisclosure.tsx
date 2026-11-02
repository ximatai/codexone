import { Accordion } from "@mantine/core";
import type { ReactNode } from "react";

export function UsageDisclosure({
  title,
  children,
  className,
}: {
  title: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <Accordion
      variant="default"
      className={className}
      styles={{
        item: { border: 0 },
        control: {
          padding: "4px 0",
          fontSize: "var(--mantine-font-size-sm)",
          color: "var(--mantine-primary-color-filled)",
        },
        content: { padding: "8px 0" },
      }}
    >
      <Accordion.Item value="content">
        <Accordion.Control>{title}</Accordion.Control>
        <Accordion.Panel>{children}</Accordion.Panel>
      </Accordion.Item>
    </Accordion>
  );
}
