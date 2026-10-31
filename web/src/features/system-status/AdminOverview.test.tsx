import { act, fireEvent, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { renderPrivate } from "../../../tests/render";
import { AdminOverview } from "./AdminOverview";
import * as management from "../../shared/management";
import * as accounts from "../account-management/api";
import * as usage from "../usage/api";
import { parseObservability } from "../account-management/observation-api";
import { observationFixture } from "../account-management/observation.test-data";
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn(),
  request: vi.fn(),
}));
vi.mock("../account-management/api", () => ({ fetchAccounts: vi.fn() }));
vi.mock("../usage/api", () => ({ fetchKeyUsage: vi.fn() }));
afterEach(() => {
  vi.clearAllMocks();
  vi.useRealTimers();
});
it("shows authenticated daily totals, preserves missing costs, and opens actual storage details", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(management.request).mockResolvedValue({
    pressure: "normal",
    admissionAllowed: true,
    optionalWorkAllowed: true,
    availableBytes: 1048576,
  });
  vi.mocked(accounts.fetchAccounts).mockResolvedValue([
    {
      id: "synthetic-account",
      revision: 1,
      credentialVersion: 1,
      mode: "enabled",
      authorization: "ready",
      createdAtUnixSeconds: 1,
    },
  ]);
  vi.mocked(usage.fetchKeyUsage).mockResolvedValue([
    {
      keyID: "alpha",
      principal: "synthetic-team",
      admitted: 2,
      failed: 1,
      pending: 1,
      estimatedMicros: "1250000",
      lastUsedAtUnixSeconds: 1,
    },
    {
      keyID: "beta",
      principal: "other-team",
      admitted: 1,
      failed: 0,
      pending: 1,
      estimatedMicros: null,
      lastUsedAtUnixSeconds: 1,
    },
  ]);
  const view = renderPrivate(<AdminOverview />);
  await screen.findByText(/允许准入/);
  expect(accounts.fetchAccounts).toHaveBeenCalledTimes(1);
  expect(usage.fetchKeyUsage).toHaveBeenCalledTimes(1);
  expect(
    vi
      .mocked(management.request)
      .mock.calls.filter(([path]) => path === "/api/runtime/storage"),
  ).toHaveLength(1);
  expect(screen.queryByText("今日请求 / 失败")).toBeNull();
  expect(screen.queryByText("费用：估算 $1.25")).toBeNull();
  expect(screen.getByText(/允许准入/)).toBeVisible();
  fireEvent.click(screen.getByRole("link", { name: /存储与准入/ }));
  expect(await screen.findByText("磁盘可用：1.0 MiB")).toBeVisible();
  expect(document.querySelector('[data-ui-overlay="true"]')).not.toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "关闭" }));
  expect(document.querySelector('[data-ui-overlay="true"]')).toBeNull();
  fireEvent.click(screen.getByRole("link", { name: /存储与准入/ }));
  expect(document.querySelector('[data-ui-overlay="true"]')).not.toBeNull();
  view.unmount();
  expect(document.querySelector('[data-ui-overlay="true"]')).toBeNull();
  expect(management.request).toHaveBeenCalledWith(
    "/api/runtime/storage",
    expect.objectContaining({ signal: expect.any(AbortSignal) }),
  );
});

it.each(["fresh", "unavailable"] as const)(
  "ages %s quota using monotonic time while preserving unavailable",
  async (state) => {
    vi.mocked(management.fetchSession).mockResolvedValue({
      csrf: "synthetic-csrf",
    });
    vi.mocked(management.request).mockResolvedValue({
      pressure: "normal",
      admissionAllowed: true,
      optionalWorkAllowed: true,
    });
    vi.mocked(usage.fetchKeyUsage).mockResolvedValue([]);
    vi.useFakeTimers({
      toFake: ["setInterval", "clearInterval", "performance"],
    });
    const summary = parseObservability(observationFixture());
    summary.quota.state = state;
    summary.quota.freshForSeconds = state === "fresh" ? 290 : 0;
    if (state === "unavailable") summary.quota.limits = [];
    vi.mocked(accounts.fetchAccounts).mockResolvedValue([
      {
        id: "synthetic-account",
        revision: 1,
        credentialVersion: 1,
        mode: "enabled",
        authorization: "ready",
        createdAtUnixSeconds: 1,
        observability: summary,
      },
    ]);
    const view = renderPrivate(<AdminOverview />);
    await screen.findByText(
      state === "fresh" ? "synthetic-account" : "额度不可用",
    );
    fireEvent.click(await screen.findByLabelText("自动刷新（15 秒）"));
    await act(async () => {});
    const reads = vi.mocked(accounts.fetchAccounts).mock.calls.length;
    await act(async () => vi.advanceTimersByTime(300000));
    expect(
      screen.getByText(state === "fresh" ? "额度观测已陈旧" : "额度不可用"),
    ).toBeVisible();
    if (state === "unavailable")
      expect(screen.queryByText("额度观测已陈旧")).toBeNull();
    expect(accounts.fetchAccounts).toHaveBeenCalledTimes(reads);
    view.unmount();
  },
);
