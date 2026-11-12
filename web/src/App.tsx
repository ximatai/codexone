import { AttentionNavigationObserver } from "./shared/attention-navigation";
import { Notifications } from "@mantine/notifications";
import { WorkspaceFrame } from "./app/WorkspaceFrame";
import { MantineProvider } from "@mantine/core";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { lazy, Suspense, useEffect, useState, type ReactNode } from "react";
import { HashRouter, Navigate, Route, Routes, useLocation } from "react-router";
const AccountManagement = lazy(() =>
  import("./features/account-management/AccountManagement").then((module) => ({
    default: module.AccountManagement,
  })),
);
const ModelDirectory = lazy(() =>
  import("./features/model-directory/ModelDirectory").then((module) => ({
    default: module.ModelDirectory,
  })),
);
const KeyManagement = lazy(() =>
  import("./features/key-management/KeyManagement").then((module) => ({
    default: module.KeyManagement,
  })),
);
const AdminOverview = lazy(() =>
  import("./features/system-status/AdminOverview").then((module) => ({
    default: module.AdminOverview,
  })),
);
import { LANRiskBanner } from "./features/system-status/LANRiskBanner";
import { SystemOverview } from "./features/system-status/SystemOverview";
const UsagePage = lazy(() =>
  import("./features/usage/UsagePage").then((module) => ({
    default: module.UsagePage,
  })),
);
import { useManagementSession, ManagementSession } from "./shared/session";
import { busyRetryDelay, retryWhenBusy } from "./shared/query-retry";
import { theme } from "./app/theme";
function OwnedQueries({ children }: { children: ReactNode }) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            retry: retryWhenBusy,
            retryDelay: (attempt) => busyRetryDelay(attempt),
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
function PublicSystemStatus() {
  const owner = useManagementSession();
  return owner.session ? null : <SystemOverview />;
}
function Workspace() {
  const location = useLocation();
  return (
    <WorkspaceFrame>
      <main>
        <LANRiskBanner />
        <ManagementSession publicView={location.pathname === "/"}>
          <OwnedQueries>
            <AttentionNavigationObserver />
            <Suspense
              key={location.pathname}
              fallback={<p role="status">正在打开页面…</p>}
            >
              <Routes>
                <Route
                  path="/"
                  element={
                    <>
                      <AdminOverview />
                      <PublicSystemStatus />
                    </>
                  }
                />
                <Route path="/models" element={<ModelDirectory />} />
                <Route path="/keys" element={<KeyManagement />} />
                <Route path="/accounts" element={<AccountManagement />} />
                <Route path="/usage" element={<UsagePage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </Suspense>
          </OwnedQueries>
        </ManagementSession>
      </main>
    </WorkspaceFrame>
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
      <Notifications position="bottom-right" />
      <HashRouter>
        <Workspace />
      </HashRouter>
    </MantineProvider>
  );
}
