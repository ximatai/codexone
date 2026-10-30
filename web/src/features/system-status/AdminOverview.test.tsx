import { fireEvent, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { renderPrivate } from "../../../tests/render";
import { AdminOverview } from "./AdminOverview";
import * as management from "../../shared/management";
import * as accounts from "../account-management/api";
import * as usage from "../usage/api";
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn(),
  request: vi.fn(),
}));
vi.mock("../account-management/api", () => ({ fetchAccounts: vi.fn() }));
vi.mock("../usage/api", () => ({ fetchKeyUsage: vi.fn() }));
afterEach(() => vi.clearAllMocks());
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
  renderPrivate(<AdminOverview />);
  expect(await screen.findByText("费用：估算 $1.25")).toBeVisible();
  expect(screen.getByText("3 / 1")).toBeVisible();
  expect(screen.getByText("允许准入")).toBeVisible();
  fireEvent.click(screen.getByRole("link", { name: "存储与准入状态" }));
  expect(await screen.findByText("磁盘可用：1.0 MiB")).toBeVisible();
  expect(management.request).toHaveBeenCalledWith(
    "/api/runtime/storage",
    expect.objectContaining({ signal: expect.any(AbortSignal) }),
  );
});
