import { act, fireEvent, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { renderPrivate } from "../../../tests/render";
import { AdminOverview } from "./AdminOverview";
import * as management from "../../shared/management";
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn(() => Promise.resolve({ csrf: "synthetic-csrf" })),
  request: vi.fn(),
}));
vi.mock("../account-management/api", () => ({
  fetchAccounts: vi.fn(() => Promise.resolve([])),
}));
vi.mock("../usage/api", () => ({
  fetchKeyUsage: vi.fn(() => Promise.resolve([])),
}));
vi.mock("./round2-api", async (original) => ({
  ...(await original<typeof import("./round2-api")>()),
  fetchDaily: vi.fn(() => Promise.resolve([])),
  fetchInFlight: vi.fn(() => Promise.resolve([])),
  fetchRecent: vi.fn(() => Promise.resolve({ rows: [], truncated: false })),
}));
afterEach(() => {
  vi.useRealTimers();
  vi.clearAllMocks();
});
it("refreshes attention with the homepage and honors the shared pause switch", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  vi.mocked(management.request).mockImplementation(async (path) =>
    path === "/api/attention"
      ? { items: [], generatedAtUnixSeconds: 1 }
      : {
          pressure: "normal",
          admissionAllowed: true,
          optionalWorkAllowed: true,
        },
  );
  const view = renderPrivate(<AdminOverview />);
  await screen.findByText("暂无需要处理的事项");
  const reads = () =>
    vi
      .mocked(management.request)
      .mock.calls.filter(([path]) => path === "/api/attention").length;
  expect(reads()).toBe(1);
  await act(async () => vi.advanceTimersByTime(15000));
  expect(reads()).toBe(2);
  fireEvent.click(screen.getByLabelText("自动刷新（15 秒）"));
  await act(async () => vi.advanceTimersByTime(30000));
  expect(reads()).toBe(2);
  fireEvent.click(screen.getByRole("button", { name: "刷新请求概览" }));
  await act(async () => {});
  expect(reads()).toBe(3);
  view.unmount();
});
