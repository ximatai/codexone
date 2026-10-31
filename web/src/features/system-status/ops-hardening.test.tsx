import { fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { notifications } from "@mantine/notifications";
import { renderPrivate } from "../../../tests/render";
import { AdminOverview } from "./AdminOverview";
import * as management from "../../shared/management";
import * as accounts from "../account-management/api";
import * as usage from "../usage/api";
import { attentionMessage } from "./attention-api";
vi.mock("./ActivityOverview", () => ({
  ActivityOverview: ({
    attention,
    sidebar,
  }: {
    attention: React.ReactNode;
    sidebar: React.ReactNode;
  }) => (
    <>
      {attention}
      {sidebar}
    </>
  ),
}));
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn(),
  request: vi.fn(),
}));
vi.mock("../account-management/api", () => ({ fetchAccounts: vi.fn() }));
vi.mock("../usage/api", () => ({ fetchKeyUsage: vi.fn() }));
afterEach(() => vi.clearAllMocks());
const item = {
  kind: "unresolved_executions" as const,
  severity: "warning" as const,
  subjectType: "system" as const,
  subjectID: null,
  subjectName: null,
  detail: { count: 500, unresolvedCount: 512, limit: 1024 },
  sinceUnixSeconds: 1,
};
function setup(conflict = false) {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(accounts.fetchAccounts).mockResolvedValue([
    {
      id: "12345678-abcd",
      displayName: "合成账号",
      revision: 1,
      credentialVersion: 1,
      mode: "enabled",
      authorization: "ready",
      createdAtUnixSeconds: 1,
      accessExpiresAtUnixSeconds: Math.floor(Date.now() / 1000) + 3600,
    },
  ]);
  vi.mocked(usage.fetchKeyUsage).mockResolvedValue([]);
  vi.mocked(management.request).mockImplementation(async (path) => {
    if (path === "/api/attention")
      return { items: [item], generatedAtUnixSeconds: 1 };
    if (path === "/api/executions/unknown/release") {
      if (conflict) throw new management.ManagementError(409, "conflict");
      return { released: 500 };
    }
    return {
      pressure: "normal",
      admissionAllowed: true,
      optionalWorkAllowed: true,
    };
  });
  return renderPrivate(<AdminOverview />);
}
it("requires confirmation, cancels safely, releases unknown count and preserves unknown-use copy", async () => {
  const show = vi.spyOn(notifications, "show");
  setup();
  await screen.findByText("访问凭证约 1 小时后到期");
  expect(screen.getByText(/未结执行占用 512 \/ 1024/)).toBeVisible();
  fireEvent.click(await screen.findByRole("button", { name: "核对并释放" }));
  expect(await screen.findByText(/真实用量无法得知/)).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "取消" }));
  expect(
    vi
      .mocked(management.request)
      .mock.calls.some(([path]) => path.includes("/release")),
  ).toBe(false);
  await waitFor(() =>
    expect(screen.queryByRole("button", { name: "确认释放" })).toBeNull(),
  );
  fireEvent.click(screen.getByRole("button", { name: "核对并释放" }));
  fireEvent.click(await screen.findByRole("button", { name: "确认释放" }));
  await waitFor(() =>
    expect(management.request).toHaveBeenCalledWith(
      "/api/executions/unknown/release",
      expect.objectContaining({
        method: "POST",
        csrf: "synthetic-csrf",
        body: { beforeUnixSeconds: expect.any(Number), expectedCount: 500 },
      }),
    ),
  );
  await waitFor(() =>
    expect(show).toHaveBeenCalledWith(
      expect.objectContaining({
        message: "已释放容量占用，统计仍显示用量未知。",
      }),
    ),
  );
});
it("refreshes changed counts after a conflict without replaying release", async () => {
  const show = vi.spyOn(notifications, "show");
  setup(true);
  fireEvent.click(await screen.findByRole("button", { name: "核对并释放" }));
  fireEvent.click(await screen.findByRole("button", { name: "确认释放" }));
  await waitFor(() =>
    expect(show).toHaveBeenCalledWith(
      expect.objectContaining({
        message: expect.stringContaining("待核对数量已变化"),
      }),
    ),
  );
  expect(
    vi
      .mocked(management.request)
      .mock.calls.filter(([path]) => path === "/api/attention"),
  ).toHaveLength(2);
  expect(
    vi
      .mocked(management.request)
      .mock.calls.filter(([path]) => path.includes("/release")),
  ).toHaveLength(1);
});
it("maps reminder account IDs and falls back when no account matches", () => {
  const reminder = {
    ...item,
    kind: "account_requires_auth" as const,
    subjectType: "account" as const,
    subjectID: "12345678-abcd",
  };
  expect(
    attentionMessage(reminder, [
      { id: reminder.subjectID, displayName: "合成账号" },
    ]),
  ).toContain("合成账号：");
  expect(attentionMessage(reminder)).toContain("未命名账号 · 12345678：");
});
