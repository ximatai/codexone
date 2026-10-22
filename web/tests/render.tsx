import { MantineProvider } from "@mantine/core";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { MemoryRouter } from "react-router";
import { render as testingRender } from "@testing-library/react";
import { ManagementSession } from "../src/shared/session";
function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { retry: false, gcTime: 0 } },
      }),
  );
  return (
    <MantineProvider env="test">
      <MemoryRouter>
        <QueryClientProvider client={client}>{children}</QueryClientProvider>
      </MemoryRouter>
    </MantineProvider>
  );
}
export function render(ui: ReactNode) {
  return testingRender(ui, { wrapper: Providers });
}
export function renderPrivate(ui: ReactNode) {
  return render(<ManagementSession>{ui}</ManagementSession>);
}
