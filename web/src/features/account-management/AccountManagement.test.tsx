import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { AccountManagement } from "./AccountManagement";
import * as api from "./api";
import * as sessions from "../../shared/management";
vi.mock("./api");
vi.mock("../../shared/management", async (original) => ({ ...await original<typeof import("../../shared/management")>(), fetchSession: vi.fn() }));
const account: api.Account = { id: "account", revision: 1, credentialVersion: 1, mode: "disabled", authorization: "ready", createdAtUnixSeconds: 1 };
afterEach(() => { vi.restoreAllMocks(); vi.clearAllMocks(); });
function setup() {
  vi.mocked(sessions.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchAccounts).mockResolvedValue([account]);
  return render(<AccountManagement />);
}
it("locks writes after unknown results until a successful account read", async () => {
  vi.mocked(api.setMode).mockRejectedValue(new sessions.ManagementError(0, "connection_failed"));
  setup();
  await screen.findByRole("button", { name: "启用" });
  await waitFor(() => expect(screen.getByRole("button", { name: "启用" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "启用" }));
  await screen.findByText(/操作结果未确认/);
  expect(screen.getByRole("button", { name: "启用" })).toBeDisabled();
  vi.mocked(api.fetchAccounts).mockRejectedValueOnce(new Error("network"));
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await screen.findByText(/账号读取失败/);
  expect(screen.getByRole("button", { name: "启用" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "启用" })).toBeEnabled());
  expect(api.setMode).toHaveBeenCalledTimes(1);
});
it("clears one-shot callback after failed submission and never offers replay", async () => {
  vi.mocked(api.beginAuthorization).mockResolvedValue({ flowID: "flow", authorizationURL: "https://auth.openai.com/oauth/authorize?state=synthetic", expiresInSeconds: 600 });
  vi.mocked(api.completeAuthorization).mockRejectedValue(new sessions.ManagementError(0, "connection_failed"));
  setup();
  await waitFor(() => expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  const input = await screen.findByLabelText("2. 粘贴完整回调地址");
  fireEvent.change(input, { target: { value: "private-callback-value" } });
  fireEvent.click(screen.getByRole("button", { name: "验证并保存" }));
  await screen.findByText(/操作结果未确认/);
  expect(screen.queryByLabelText("2. 粘贴完整回调地址")).not.toBeInTheDocument();
  expect(document.body.innerHTML).not.toContain("private-callback-value");
  expect(api.completeAuthorization).toHaveBeenCalledTimes(1);
});
it("ignores an authorization response arriving after leaving the page", async () => {
  let resolve: (value: api.AuthorizationFlow) => void = () => {};
  vi.mocked(api.beginAuthorization).mockReturnValue(new Promise((done) => { resolve = done; }));
  const view = setup();
  await waitFor(() => expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  view.unmount();
  await act(async () => { resolve({ flowID: "flow", authorizationURL: "https://auth.openai.com/oauth/authorize?state=private", expiresInSeconds: 600 }); });
  expect(document.body.innerHTML).not.toContain("state=private");
});

it("clears account data and permits only logout retry while logout is unconfirmed", async () => {
  const logout = vi.spyOn(sessions, "logout").mockRejectedValueOnce(new sessions.ManagementError(0, "connection_failed")).mockResolvedValueOnce(undefined);
  setup();
  await screen.findByText("授权有效");
  fireEvent.click(screen.getByRole("button", { name: "登出" }));
  await screen.findByText("登出未确认，请再次登出。");
  expect(screen.queryByText("授权有效")).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "重新读取账号" })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "启用" })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "重试登出" }));
  await screen.findByRole("heading", { name: "管理员登录" });
  expect(logout).toHaveBeenCalledTimes(2);
});
it("refreshes replaced session proof and discards its old-owner authorization flow", async () => {
  vi.mocked(api.beginAuthorization).mockResolvedValue({ flowID: "flow", authorizationURL: "https://auth.openai.com/oauth/authorize?state=old", expiresInSeconds: 600 });
  vi.mocked(api.setMode).mockResolvedValue({ ...account, mode: "enabled", revision: 2 });
  setup();
  await waitFor(() => expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  await screen.findByLabelText("2. 粘贴完整回调地址");
  await waitFor(() => expect(screen.getByRole("button", { name: "重新读取账号" })).toBeEnabled());
  vi.mocked(sessions.fetchSession).mockResolvedValue({ csrf: "new-synthetic-csrf" });
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await screen.findByText(/管理会话已更新/);
  expect(screen.queryByLabelText("2. 粘贴完整回调地址")).not.toBeInTheDocument();
  await waitFor(() => expect(screen.getByRole("button", { name: "启用" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "启用" }));
  await waitFor(() => expect(api.setMode).toHaveBeenCalledWith(account, "enabled", "new-synthetic-csrf", expect.any(AbortSignal)));
});
