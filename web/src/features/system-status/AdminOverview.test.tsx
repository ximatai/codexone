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
  expect(await screen.findByText("费用：估算 $1.25")).toBeVisible();
  expect(screen.getByText("3 / 1")).toBeVisible();
  expect(screen.getByText("允许准入")).toBeVisible();
  fireEvent.click(screen.getByRole("link", { name: "存储与准入状态" }));
  expect(await screen.findByText("磁盘可用：1.0 MiB")).toBeVisible();
  expect(document.body).toHaveClass("management-overlay-open");
  fireEvent.click(screen.getByRole("button", { name: "关闭" }));
  expect(document.body).not.toHaveClass("management-overlay-open");
  fireEvent.click(screen.getByRole("link", { name: "存储与准入状态" }));
  expect(document.body).toHaveClass("management-overlay-open");
  view.unmount();
  expect(document.body).not.toHaveClass("management-overlay-open");
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
      state === "fresh" ? "最近读取的额度观测" : "额度不可用",
    );
    await act(async () => vi.advanceTimersByTime(300000));
    expect(
      screen.getByText(state === "fresh" ? "额度观测已陈旧" : "额度不可用"),
    ).toBeVisible();
    if (state === "unavailable")
      expect(screen.queryByText("额度观测已陈旧")).toBeNull();
    expect(accounts.fetchAccounts).toHaveBeenCalledTimes(1);
    view.unmount();
  },
);
