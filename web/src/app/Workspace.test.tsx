import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { App } from "../App";
import * as sessions from "../shared/management";
import * as keys from "../features/key-management/api";
import * as usage from "../features/usage/api";
import { reportFixture } from "../features/usage/usage.test-data";
vi.mock("../shared/management", async (original) => ({
  ...(await original<typeof sessions>()),
  fetchSession: vi.fn(),
  logout: vi.fn(),
}));
vi.mock("../features/key-management/api", async (original) => ({
  ...(await original<typeof keys>()),
  fetchKeys: vi.fn(),
  fetchOptions: vi.fn(),
  createKey: vi.fn(),
}));
vi.mock("../features/usage/api", async (original) => ({
  ...(await original<typeof usage>()),
  fetchUsage: vi.fn(),
  fetchUsageOptions: vi.fn(),
}));
vi.mock("../features/system-status/api", () => ({
  fetchSystemStatus: vi.fn(() => Promise.resolve({ ready: false, checks: [] })),
}));
const key: keys.ManagedKey = {
  id: "key-1",
  principal: "team",
  revision: 1,
  enabled: true,
  models: ["synthetic-text"],
  limits: {
    requests: 10,
    active: 2,
    unresolved: 4,
    budgetMicros: 100,
    unresolvedMicros: 100,
  },
  createdAtUnixSeconds: 1,
};
beforeEach(() => {
  window.location.hash = "/keys";
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-proof",
  });
  vi.mocked(keys.fetchKeys).mockResolvedValue([key]);
  vi.mocked(keys.fetchOptions).mockResolvedValue({
    models: ["synthetic-text"],
    imageModels: [],
  });
  vi.mocked(usage.fetchUsageOptions).mockResolvedValue({
    keys: [key.id],
    models: ["synthetic-text"],
    failures: [],
  });
  vi.mocked(usage.fetchUsage).mockResolvedValue(
    usage.parseUsage(reportFixture()),
  );
});
afterEach(() => {
  vi.clearAllMocks();
});
it("links a Key to a standalone URL-owned usage filter without a duplicate report fetch", async () => {
  render(<App />);
  await screen.findByText("team");
  fireEvent.click(screen.getByRole("link", { name: "用量" }));
  await screen.findByText("请求明细");
  expect(window.location.hash).toContain("/usage?");
  expect(window.location.hash).toContain("key=key-1");
  expect(usage.fetchUsage).toHaveBeenCalledTimes(1);
  expect(usage.fetchUsage).toHaveBeenLastCalledWith(
    expect.objectContaining({ key: "key-1" }),
    null,
    expect.any(AbortSignal),
  );
  fireEvent.change(screen.getByLabelText("模型"), {
    target: { value: "historical-model" },
  });
  fireEvent.click(screen.getByRole("button", { name: "查询用量" }));
  await waitFor(() =>
    expect(window.location.hash).toContain("model=historical-model"),
  );
  expect(usage.fetchUsage).toHaveBeenCalledTimes(2);
  expect(screen.queryByText("创建密钥")).toBeNull();
});
it("requires a successful reconciliation read after an unknown write even across navigation", async () => {
  vi.mocked(keys.createKey).mockRejectedValue(
    new sessions.ManagementError(0, "connection_failed"),
  );
  render(<App />);
  await screen.findByText("team");
  fireEvent.click(screen.getByRole("button", { name: "创建密钥" }));
  fireEvent.change(await screen.findByLabelText("主体标识"), {
    target: { value: "new-team" },
  });
  fireEvent.click(screen.getByLabelText("synthetic-text"));
  fireEvent.click(screen.getByRole("button", { name: "创建 API Key" }));
  await screen.findByText(/操作结果尚未确认/);
  // Leaving discards the form. A failed read on return cannot release the owner lock.
  fireEvent.click(screen.getByRole("link", { name: "服务概览" }));
  vi.mocked(keys.fetchKeys).mockRejectedValueOnce(
    new sessions.ManagementError(0, "connection_failed"),
  );
  fireEvent.click(screen.getByRole("link", { name: "访问密钥" }));
  await screen.findByRole("alert");
  expect(screen.getByRole("button", { name: "创建密钥" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "刷新列表" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "创建密钥" })).toBeEnabled(),
  );
  expect(keys.createKey).toHaveBeenCalledTimes(1);
});
it("keeps logout uncertainty across routes and never restores data by reading again", async () => {
  vi.mocked(sessions.logout)
    .mockRejectedValueOnce(new sessions.ManagementError(0, "connection_failed"))
    .mockResolvedValueOnce(undefined);
  render(<App />);
  await screen.findByText("team");
  fireEvent.click(screen.getByRole("button", { name: "退出登录" }));
  await screen.findByText(/服务端登出尚未确认/);
  const before = vi.mocked(keys.fetchKeys).mock.calls.length;
  fireEvent.click(screen.getByRole("link", { name: "用量与诊断" }));
  expect(screen.getByRole("button", { name: "重试登出" })).toBeVisible();
  expect(keys.fetchKeys).toHaveBeenCalledTimes(before);
  expect(usage.fetchUsage).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "重试登出" }));
  await screen.findByRole("heading", { name: "管理员登录" });
  expect(sessions.logout).toHaveBeenCalledTimes(2);
});
