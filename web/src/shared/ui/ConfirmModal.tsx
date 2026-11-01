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
  returnFocusTo,
  zIndex,
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
  returnFocusTo?: () => void;
  zIndex?: number;
}) {
  return (
    <Modal
      zIndex={zIndex}
      removeScrollProps={{ removeScrollBar: false }}
      data-ui-overlay={opened || undefined}
      opened={opened}
      returnFocus={returnFocusTo ? false : true}
      onExitTransitionEnd={returnFocusTo}
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
