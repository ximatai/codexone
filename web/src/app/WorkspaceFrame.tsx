import { AttentionNavigation } from "../shared/attention-navigation";
import styles from "./Workspace.module.css";
import { Burger, Drawer, Group, Stack, Text } from "@mantine/core";
import {
  IconLayoutDashboard,
  IconUsers,
  IconKey,
  IconChartBar,
} from "@tabler/icons-react";
import { NavLink, useLocation } from "react-router";
import { useEffect, useState, type ReactNode } from "react";
const links = [
  { path: "/", title: "服务概览", icon: IconLayoutDashboard },
  { path: "/accounts", title: "订阅账号", icon: IconUsers },
  { path: "/keys", title: "访问密钥", icon: IconKey },
  { path: "/usage", title: "用量与诊断", icon: IconChartBar },
];
/** Static shell geometry avoids AppShell's unconditional inline media-style element under CSP. */
export function WorkspaceFrame({ children }: { children: ReactNode }) {
  const [opened, setOpened] = useState(false);
  const location = useLocation();
  const [critical, setCritical] = useState(false);
  useEffect(() => setOpened(false), [location.pathname]);
  const navigation = (
    <Stack gap={6}>
      {links.map(({ path, title, icon: Icon }) => (
        <NavLink
          className={styles.link}
          key={path}
          to={path}
          end
          aria-label={
            path === "/" && critical
              ? "服务概览（有需要处理的事项）"
              : undefined
          }
          onClick={() => setOpened(false)}
        >
          <Icon size={21} aria-hidden="true" />
          {title}
          {path === "/" && critical && (
            <span className={styles.attentionDot} aria-hidden="true" />
          )}
        </NavLink>
      ))}
    </Stack>
  );
  return (
    <AttentionNavigation.Provider value={setCritical}>
      <div className={styles.workspace}>
        <header className={styles.header}>
          <Burger
            className={styles.burger}
            opened={opened}
            onClick={() => setOpened((v) => !v)}
            aria-label={opened ? "关闭导航" : "打开导航"}
            size="sm"
          />
          <Group gap="sm" className={styles.brand}>
            <span className="brand-mark" aria-hidden="true">
              C
            </span>
            <Text fw={700} size="xl">
              CodexOne
            </Text>
          </Group>
        </header>
        <aside className={styles.sidebar}>
          <nav aria-label="控制台导航">{navigation}</nav>
        </aside>
        <Drawer
          opened={opened}
          onClose={() => setOpened(false)}
          title="CodexOne"
          position="left"
          size={280}
          removeScrollProps={{ removeScrollBar: false }}
          data-ui-overlay={opened || undefined}
          closeButtonProps={{ "aria-label": "关闭导航" }}
        >
          <nav aria-label="控制台导航">{navigation}</nav>
        </Drawer>
        <div className={styles.content}>{children}</div>
      </div>
    </AttentionNavigation.Provider>
  );
}
