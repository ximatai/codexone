import styles from "./app/Workspace.module.css";
import { Button, Group, MantineProvider } from "@mantine/core";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useState, type ReactNode } from "react";
import {
  HashRouter,
  NavLink,
  Navigate,
  Route,
  Routes,
  useLocation,
} from "react-router";
const AccountManagement = lazy(() =>
  import("./features/account-management/AccountManagement").then((module) => ({
    default: module.AccountManagement,
  })),
);
const KeyManagement = lazy(() =>
  import("./features/key-management/KeyManagement").then((module) => ({
    default: module.KeyManagement,
  })),
);
import { SystemOverview } from "./features/system-status/SystemOverview";
const UsagePage = lazy(() =>
  import("./features/usage/UsagePage").then((module) => ({
    default: module.UsagePage,
  })),
);
import { ManagementSession } from "./shared/session";
import { theme } from "./app/theme";
function OwnedQueries({ children }: { children: ReactNode }) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            retry: false,
            gcTime: 0,
            refetchOnWindowFocus: false,
            refetchOnReconnect: false,
            refetchOnMount: false,
          },
          mutations: { retry: false },
        },
      }),
  );
  useEffect(
    () => () => {
      void client.cancelQueries();
      client.clear();
    },
    [client],
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}
function Workspace() {
  const location = useLocation();
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
      <main>
        <ManagementSession publicView={location.pathname === "/"}>
          <OwnedQueries>
            <Suspense
              key={location.pathname}
              fallback={<p role="status">正在打开页面…</p>}
            >
              <Routes>
                <Route path="/" element={<SystemOverview />} />
                <Route path="/keys" element={<KeyManagement />} />
                <Route path="/accounts" element={<AccountManagement />} />
                <Route path="/usage" element={<UsagePage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </Suspense>
          </OwnedQueries>
        </ManagementSession>
      </main>
    </div>
  );
}
export function App() {
  return (
    <MantineProvider
      theme={theme}
      forceColorScheme="light"
      withCssVariables={false}
      withGlobalClasses={false}
    >
      <HashRouter>
        <Workspace />
      </HashRouter>
    </MantineProvider>
  );
}
