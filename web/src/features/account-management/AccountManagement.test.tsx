import { renderPrivate as render } from "../../../tests/render";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { AccountManagement } from "./AccountManagement";
import * as api from "./api";
import * as observations from "./observation-api";
import { observationFixture } from "./observation.test-data";
import * as sessions from "../../shared/management";
vi.mock("./api");
vi.mock("./observation-api", async (original) => ({
  ...(await original<typeof observations>()),
  fetchObservation: vi.fn(),
}));
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof import("../../shared/management")>()),
  fetchSession: vi.fn(),
}));
const account: api.Account = {
  id: "account",
  revision: 1,
  credentialVersion: 1,
  mode: "disabled",
  authorization: "ready",
  createdAtUnixSeconds: 1,
};
afterEach(() => {
  vi.restoreAllMocks();
  vi.clearAllMocks();
});
function setup() {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchAccounts).mockResolvedValue([account]);
  return render(<AccountManagement />);
}
it("locks writes after unknown results until a successful account read", async () => {
  vi.mocked(api.setMode).mockRejectedValue(
    new sessions.ManagementError(0, "connection_failed"),
  );
  setup();
  await screen.findByRole("button", { name: "启用" });
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "启用" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "启用" }));
  await screen.findByText(/操作结果未确认/);
  expect(screen.getByRole("button", { name: "启用" })).toBeDisabled();
  vi.mocked(api.fetchAccounts).mockRejectedValueOnce(new Error("network"));
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await screen.findByText(/账号读取失败/);
  expect(screen.getByRole("button", { name: "启用" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "启用" })).toBeEnabled(),
  );
  expect(api.setMode).toHaveBeenCalledTimes(1);
});
it("clears one-shot callback after failed submission and never offers replay", async () => {
  vi.mocked(api.beginAuthorization).mockResolvedValue({
    flowID: "flow",
    authorizationURL: "https://auth.openai.com/oauth/authorize?state=synthetic",
    expiresInSeconds: 600,
  });
  vi.mocked(api.completeAuthorization).mockRejectedValue(
    new sessions.ManagementError(0, "connection_failed"),
  );
  setup();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  const input = await screen.findByLabelText("2. 粘贴完整回调地址");
  fireEvent.change(input, { target: { value: "private-callback-value" } });
  fireEvent.click(screen.getByRole("button", { name: "3. 验证并保存" }));
  await screen.findByText(/操作结果未确认/);
  expect(
    screen.queryByLabelText("2. 粘贴完整回调地址"),
  ).not.toBeInTheDocument();
  expect(document.body.innerHTML).not.toContain("private-callback-value");
  expect(api.completeAuthorization).toHaveBeenCalledTimes(1);
});
it("ignores an authorization response arriving after leaving the page", async () => {
  let resolve: (value: api.AuthorizationFlow) => void = () => {};
  vi.mocked(api.beginAuthorization).mockReturnValue(
    new Promise((done) => {
      resolve = done;
    }),
  );
  const view = setup();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  view.unmount();
  await act(async () => {
    resolve({
      flowID: "flow",
      authorizationURL: "https://auth.openai.com/oauth/authorize?state=private",
      expiresInSeconds: 600,
    });
  });
  expect(document.body.innerHTML).not.toContain("state=private");
});

it("clears account data and permits only logout retry while logout is unconfirmed", async () => {
  const logout = vi
    .spyOn(sessions, "logout")
    .mockRejectedValueOnce(new sessions.ManagementError(0, "connection_failed"))
    .mockResolvedValueOnce(undefined);
  setup();
  await screen.findByText("授权有效");
  fireEvent.click(screen.getByRole("button", { name: "退出登录" }));
  await screen.findByText("服务端登出尚未确认。本页内容已清除，请重试登出。");
  expect(screen.queryByText("授权有效")).not.toBeInTheDocument();
  expect(
    screen.queryByRole("button", { name: "重新读取账号" }),
  ).not.toBeInTheDocument();
  expect(
    screen.queryByRole("button", { name: "启用" }),
  ).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "重试登出" }));
  await screen.findByRole("heading", { name: "管理员登录" });
  expect(logout).toHaveBeenCalledTimes(2);
});
it("refreshes replaced session proof and discards its old-owner authorization flow", async () => {
  vi.mocked(api.beginAuthorization).mockResolvedValue({
    flowID: "flow",
    authorizationURL: "https://auth.openai.com/oauth/authorize?state=old",
    expiresInSeconds: 600,
  });
  vi.mocked(api.setMode).mockResolvedValue({
    ...account,
    mode: "enabled",
    revision: 2,
  });
  setup();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  await screen.findByLabelText("2. 粘贴完整回调地址");
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "重新读取账号" })).toBeEnabled(),
  );
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "new-synthetic-csrf",
  });
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await screen.findByText(/管理会话已更新/);
  expect(
    screen.queryByLabelText("2. 粘贴完整回调地址"),
  ).not.toBeInTheDocument();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "启用" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "启用" }));
  await waitFor(() =>
    expect(api.setMode).toHaveBeenCalledWith(
      account,
      "enabled",
      "new-synthetic-csrf",
      expect.any(AbortSignal),
    ),
  );
});

it("cannot revive a late old-owner flow after a detail 401 and a new login", async () => {
  let finish!: (value: api.AuthorizationFlow) => void;
  vi.mocked(api.beginAuthorization).mockReturnValueOnce(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  vi.mocked(observations.fetchObservation).mockRejectedValueOnce(
    new sessions.ManagementError(401, "unauthorized"),
  );
  vi.spyOn(sessions, "login").mockResolvedValue({
    csrf: "synthetic-new-proof",
  });
  setup();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  await screen.findByRole("heading", { name: "管理员登录" });
  await act(async () => {
    finish({
      flowID: "old-flow",
      authorizationURL:
        "https://auth.openai.com/oauth/authorize?state=synthetic-old-owner",
      expiresInSeconds: 600,
    });
  });
  fireEvent.change(screen.getByLabelText("管理员凭证"), {
    target: { value: "synthetic-admin" },
  });
  fireEvent.click(screen.getByRole("button", { name: "登录管理台" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  expect(screen.queryByLabelText("2. 粘贴完整回调地址")).toBeNull();
  expect(document.body.innerHTML).not.toContain("synthetic-old-owner");
});

it("keeps reconciliation available inside an authorization drawer after its read fails", async () => {
  vi.mocked(api.beginAuthorization).mockResolvedValue({
    flowID: "flow",
    authorizationURL: "https://auth.openai.com/oauth/authorize?state=synthetic",
    expiresInSeconds: 600,
  });
  setup();
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "发起账号授权" })).toBeEnabled(),
  );
  vi.mocked(api.fetchAccounts).mockRejectedValueOnce(
    new Error("synthetic read failure"),
  );
  fireEvent.click(screen.getByRole("button", { name: "发起账号授权" }));
  await screen.findByText(/账号读取失败/);
  expect(screen.getByRole("button", { name: "3. 验证并保存" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "重新读取账号" }));
  await waitFor(() =>
    expect(screen.getByLabelText("2. 粘贴完整回调地址")).toBeEnabled(),
  );
  expect(api.beginAuthorization).toHaveBeenCalledTimes(1);
});
it("cancels the detail read when its drawer closes", async () => {
  let signal: AbortSignal | undefined;
  vi.mocked(observations.fetchObservation).mockImplementation((_id, value) => {
    signal = value;
    return new Promise(() => {});
  });
  setup();
  fireEvent.click(
    await screen.findByRole("button", { name: "额度与健康详情" }),
  );
  await waitFor(() => expect(signal).toBeDefined());
  fireEvent.click(screen.getByRole("button", { name: "关闭" }));
  await waitFor(() => expect(signal?.aborted).toBe(true));
});

it("confirms draining from details and explains that associated continuations and in-flight requests continue", async () => {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchAccounts).mockResolvedValue([
    { ...account, mode: "enabled" },
  ]);
  vi.mocked(observations.fetchObservation).mockRejectedValue(
    new Error("synthetic unavailable"),
  );
  vi.mocked(api.setMode).mockResolvedValue({
    ...account,
    mode: "draining",
    revision: 2,
  });
  render(<AccountManagement />);
  fireEvent.click(
    await screen.findByRole("button", { name: "额度与健康详情" }),
  );
  fireEvent.click(await screen.findByRole("button", { name: "排空" }));
  expect(
    await screen.findByText(/已有身份关联的续接请求仍可派发/),
  ).toHaveTextContent("在途请求继续");
  fireEvent.click(screen.getByRole("button", { name: "取消" }));
  expect(api.setMode).not.toHaveBeenCalled();
  fireEvent.click(await screen.findByRole("button", { name: "排空" }));
  fireEvent.click(screen.getByRole("button", { name: "确认排空" }));
  await waitFor(() => expect(api.setMode).toHaveBeenCalledOnce());
  expect(vi.mocked(api.setMode).mock.calls[0][1]).toBe("draining");
});

it("shows unavailable quota before elapsed freshness for an account with no successful observation", async () => {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  const summary = observations.parseObservability(observationFixture());
  summary.quota = {
    ...summary.quota,
    state: "unavailable",
    observedAtUnixSeconds: null,
    ageSeconds: null,
    freshForSeconds: 0,
    limits: [],
  };
  summary.receivedAt = performance.now() - 600000;
  vi.mocked(api.fetchAccounts).mockResolvedValue([
    { ...account, observability: summary },
  ]);
  render(<AccountManagement />);
  expect((await screen.findAllByText("额度不可用")).length).toBeGreaterThan(0);
  expect(screen.queryByText("额度观测已陈旧")).toBeNull();
});
it("edits display names, refreshing a conflicting revision before retry", async () => {
  vi.mocked(api.setDisplayName)
    .mockRejectedValueOnce(
      new sessions.ManagementError(409, "revision_conflict"),
    )
    .mockResolvedValue(account);
  setup();
  fireEvent.click(
    await screen.findByRole("button", { name: "额度与健康详情" }),
  );
  fireEvent.change(await screen.findByLabelText("账号显示名"), {
    target: { value: "合成账号" },
  });
  fireEvent.click(screen.getByRole("button", { name: "保存显示名" }));
  await screen.findByText(/账号已刷新/);
  expect(api.setDisplayName).toHaveBeenCalledTimes(1);
  expect(api.fetchAccounts).toHaveBeenCalledTimes(2);
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "保存显示名" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "保存显示名" }));
  await screen.findByText("显示名已更新。");
});

it("clears an existing display name explicitly", async () => {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchAccounts).mockResolvedValue([
    { ...account, displayName: "合成账号" },
  ]);
  vi.mocked(api.setDisplayName).mockResolvedValue(account);
  render(<AccountManagement />);
  await screen.findByText("合成账号");
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  fireEvent.click(await screen.findByRole("button", { name: "清除显示名" }));
  await waitFor(() =>
    expect(api.setDisplayName).toHaveBeenCalledWith(
      expect.objectContaining({ displayName: "合成账号" }),
      null,
      "synthetic-csrf",
      expect.any(AbortSignal),
    ),
  );
});

it("shows unavailable credential times in account details", async () => {
  setup();
  fireEvent.click(
    await screen.findByRole("button", { name: "额度与健康详情" }),
  );
  expect(screen.getByText("访问凭证到期：不可用")).toBeVisible();
  expect(screen.getByText("最近凭证更新：不可用")).toBeVisible();
});
it("shows local and relative credential times in account details", async () => {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  const expiry = Math.floor(Date.now() / 1000) + 10800;
  vi.mocked(api.fetchAccounts).mockResolvedValue([
    {
      ...account,
      accessExpiresAtUnixSeconds: expiry,
      credentialUpdatedAtUnixSeconds: expiry - 21600,
    },
  ]);
  render(<AccountManagement />);
  fireEvent.click(
    await screen.findByRole("button", { name: "额度与健康详情" }),
  );
  expect(screen.getByText(/访问凭证到期：.*约 3 小时后/)).toBeVisible();
  expect(screen.getByText(/最近凭证更新：.*约 3 小时前/)).toBeVisible();
  expect(screen.getByText(/访问凭证到期：/).textContent).toContain(
    new Date(expiry * 1000).toLocaleString(),
  );
});
