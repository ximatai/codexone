import styles from "./Workspace.module.css";
import { Button, Group } from "@mantine/core";
import { NavLink } from "react-router";
import type { ReactNode } from "react";
export function WorkspaceFrame({ children }: { children: ReactNode }) {
  return (
    <div className={styles.workspace}>
      <header className={styles.header}>
        <span className="brand-mark" aria-hidden="true">
          C
        </span>
        <strong>CodexOne</strong>
      </header>
      <nav aria-label="控制台导航">
        <Group gap="xs">
          {[
            ["/", "服务概览"],
            ["/accounts", "订阅账号"],
            ["/keys", "访问密钥"],
            ["/usage", "用量与诊断"],
          ].map(([path, title]) => (
            <Button
              key={path}
              component={NavLink}
              to={path}
              end
              variant="subtle"
            >
              {title}
            </Button>
          ))}
        </Group>
      </nav>
      {children}
    </div>
  );
}
