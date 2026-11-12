import { AttentionNavigation } from "../shared/attention-navigation";
import styles from "./Workspace.module.css";
import { ActionIcon, Burger, Drawer, Group, Stack, Text } from "@mantine/core";
import {
  IconLayoutDashboard,
  IconUsers,
  IconKey,
  IconChartBar,
  IconLayoutSidebarLeftCollapse,
  IconLayoutSidebarLeftExpand,
} from "@tabler/icons-react";
import { NavLink, useLocation } from "react-router";
import { useEffect, useState, type ReactNode } from "react";
const links = [
  { path: "/", title: "服务概览", icon: IconLayoutDashboard },
  { path: "/accounts", title: "订阅账号", icon: IconUsers },
  { path: "/keys", title: "访问密钥", icon: IconKey },
  { path: "/usage", title: "用量与诊断", icon: IconChartBar },
];
const sidebarPreference = "codexone.sidebar-collapsed";
/** Static shell geometry avoids AppShell's unconditional inline media-style element under CSP. */
export function WorkspaceFrame({ children }: { children: ReactNode }) {
  const [opened, setOpened] = useState(false);
  const [collapsed, setCollapsed] = useState(() => {
    try {
      return window.localStorage.getItem(sidebarPreference) === "true";
    } catch {
      return false;
    }
  });
  const location = useLocation();
  const [critical, setCritical] = useState(false);
  useEffect(() => setOpened(false), [location.pathname]);
  const toggleLabel = collapsed ? "展开侧栏" : "收起侧栏";
  function toggleSidebar() {
    const next = !collapsed;
    setCollapsed(next);
    try {
      window.localStorage.setItem(sidebarPreference, String(next));
    } catch {
      // The in-memory preference still applies when storage is unavailable.
    }
  }
  const navigation = (
    <Stack gap={6}>
      {links.map(({ path, title, icon: Icon }) => (
        <NavLink
          className={styles.link}
          key={path}
          to={path}
          end
          aria-label={
            path === "/" && critical ? "服务概览（有需要处理的事项）" : title
          }
          title={collapsed ? title : undefined}
          onClick={() => setOpened(false)}
        >
          <Icon size={21} aria-hidden="true" />
          <span className={styles.linkTitle}>{title}</span>
          {path === "/" && critical && (
            <span className={styles.attentionDot} aria-hidden="true" />
          )}
        </NavLink>
      ))}
    </Stack>
  );
  return (
    <AttentionNavigation.Provider value={setCritical}>
      <div
        className={styles.workspace}
        data-sidebar-collapsed={collapsed || undefined}
      >
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
        <aside id="workspace-sidebar" className={styles.sidebar}>
          <nav aria-label="控制台导航">{navigation}</nav>
          <ActionIcon
            className={styles.sidebarToggle}
            variant="subtle"
            color="gray"
            size="lg"
            aria-label={toggleLabel}
            aria-controls="workspace-sidebar"
            aria-expanded={!collapsed}
            title={toggleLabel}
            onClick={toggleSidebar}
          >
            {collapsed ? (
              <IconLayoutSidebarLeftExpand size={21} aria-hidden="true" />
            ) : (
              <IconLayoutSidebarLeftCollapse size={21} aria-hidden="true" />
            )}
          </ActionIcon>
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
