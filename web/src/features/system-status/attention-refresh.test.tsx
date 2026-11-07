import { dailyReport, keyReport } from "../../../tests/usage-reports";
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
  fetchDaily: vi.fn(() => Promise.resolve(dailyReport([]))),
  fetchInFlight: vi.fn(() => Promise.resolve([])),
  fetchKeySummary: vi.fn(() => Promise.resolve(keyReport([]))),
}));
afterEach(() => {
  vi.useRealTimers();
  vi.clearAllMocks();
});
it("refreshes attention with the homepage and stops polling when the document is hidden", async () => {
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
  const hidden = vi.spyOn(document, "hidden", "get").mockReturnValue(true);
  fireEvent(document, new Event("visibilitychange"));
  await act(async () => vi.advanceTimersByTime(30000));
  expect(reads()).toBe(2);
  hidden.mockRestore();
  view.unmount();
});
