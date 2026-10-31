import { Button, Group, Modal, Stack } from "@mantine/core";
import type { ReactNode } from "react";
export function ConfirmModal({
  opened,
  title,
  busy,
  disabled,
  close,
  confirm,
  label,
  children,
  destructive = false,
}: {
  opened: boolean;
  title: string;
  busy: boolean;
  disabled: boolean;
  close: () => void;
  confirm: () => void;
  label: string;
  children: ReactNode;
  destructive?: boolean;
}) {
  return (
    <Modal
      removeScrollProps={{ removeScrollBar: false }}
      data-ui-overlay="true"
      opened={opened}
      onClose={() => {
        if (!busy) close();
      }}
      title={title}
      closeButtonProps={{ "aria-label": "关闭" }}
      closeOnEscape={!busy}
      closeOnClickOutside={!busy}
      withCloseButton={!busy}
    >
      <Stack>
        {children}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={close}>
            取消
          </Button>
          <Button
            color={destructive ? "red" : undefined}
            disabled={disabled}
            onClick={confirm}
          >
            {label}
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}
