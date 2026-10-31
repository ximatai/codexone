import { useQueryClient, type QueryClient } from "@tanstack/react-query";
import { renderPrivate as render } from "../../../tests/render";
import * as sessions from "../../shared/management";
import { beforeEach } from "vitest";
import {
  act,
  fireEvent,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { KeyManagement } from "./KeyManagement";
import * as api from "./api";
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof sessions>()),
  fetchSession: vi.fn(),
}));
beforeEach(() => {
  vi.mocked(sessions.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
});
vi.mock("./api", async (original) => ({
  ...(await original<typeof api>()),
  fetchSession: vi.fn(),
  fetchKeys: vi.fn(),
  fetchOptions: vi.fn(),
  createKey: vi.fn(),
  updateKey: vi.fn(),
  setExpiration: vi.fn(),
}));
const key: api.ManagedKey = {
  id: "key-1",
  principal: "team",
  revision: 1,
  enabled: true,
  models: ["synthetic-text"],
  limits: {
    requests: 10,
    active: 2,
    unresolved: 4,
    budgetMicros: 1000,
    unresolvedMicros: 1000,
  },
  createdAtUnixSeconds: 1,
};
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});
it("clears one-time secrets on expiry and ignores a late clipboard completion", async () => {
  Object.defineProperty(HTMLDialogElement.prototype, "showModal", {
    configurable: true,
    value: function (this: HTMLDialogElement) {
      this.open = true;
    },
  });
  Object.defineProperty(HTMLDialogElement.prototype, "close", {
    configurable: true,
    value: function (this: HTMLDialogElement) {
      this.open = false;
    },
  });
  vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchKeys).mockResolvedValue([]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: ["synthetic-text"],
    imageModels: [],
  });
  vi.mocked(api.createKey).mockResolvedValue({
    key,
    secret: "synthetic-one-time-secret",
  });
  let copied: (() => void) | undefined;
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: {
      writeText: vi.fn(
        () =>
          new Promise<void>((resolve) => {
            copied = resolve;
          }),
      ),
    },
  });
  let client!: QueryClient;
  function CacheProbe() {
    client = useQueryClient();
    return null;
  }
  const view = render(
    <>
      <KeyManagement />
      <CacheProbe />
    </>,
  );
  await screen.findByText("尚未创建密钥。");
  fireEvent.click(screen.getByRole("button", { name: "创建密钥" }));
  fireEvent.change(screen.getByLabelText("主体标识"), {
    target: { value: "team" },
  });
  fireEvent.click(screen.getByLabelText("synthetic-text"));
  vi.useFakeTimers();
  await act(async () => {
    fireEvent.click(
      within(screen.getByRole("dialog", { name: "创建密钥" })).getByRole(
        "button",
        { name: "创建密钥" },
      ),
    );
  });
  expect(screen.getByLabelText("新 API Key")).toHaveValue(
    "synthetic-one-time-secret",
  );
  const cached = JSON.stringify({
    queries: client
      .getQueryCache()
      .getAll()
      .map((item) => item.state),
    mutations: client
      .getMutationCache()
      .getAll()
      .map((item) => item.state),
  });
  expect(cached).not.toContain("synthetic-one-time-secret");
  fireEvent.click(screen.getByText("复制凭证"));
  await act(async () => {
    vi.advanceTimersByTime(300_000);
  });
  expect(screen.queryByLabelText("新 API Key")).not.toBeInTheDocument();
  await act(async () => {
    copied?.();
  });
  expect(screen.queryByText("已复制")).not.toBeInTheDocument();
  view.unmount();
});
it("cancels owned reads when leaving the page", async () => {
  let read: AbortSignal | undefined;
  vi.mocked(api.fetchSession).mockImplementation((signal) => {
    read = signal;
    return new Promise(() => {});
  });
  const view = render(<KeyManagement />);
  await waitFor(() => expect(read).toBeDefined());
  view.unmount();
  expect(read?.aborted).toBe(true);
  expect(api.fetchKeys).not.toHaveBeenCalled();
});
it("creates an image-only key without granting vision or a conversation model", async () => {
  vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchKeys).mockResolvedValue([]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: ["synthetic-host"],
    imageModels: ["synthetic-image"],
  });
  vi.mocked(api.createKey).mockResolvedValue({
    key: {
      ...key,
      models: [],
      imageGeneration: true,
      imageModels: ["synthetic-image"],
    },
    secret: "synthetic-once",
  });
  const view = render(<KeyManagement />);
  await screen.findByText("尚未创建密钥。");
  fireEvent.click(screen.getByRole("button", { name: "创建密钥" }));
  fireEvent.change(screen.getByLabelText("主体标识"), {
    target: { value: "images-team" },
  });
  fireEvent.click(screen.getByLabelText("图片生成与参考图编辑"));
  fireEvent.click(screen.getByLabelText("synthetic-image"));
  fireEvent.click(
    within(screen.getByRole("dialog", { name: "创建密钥" })).getByRole(
      "button",
      { name: "创建密钥" },
    ),
  );
  await waitFor(() => expect(api.createKey).toHaveBeenCalled());
  expect(vi.mocked(api.createKey).mock.calls[0][0]).toMatchObject({
    principal: "images-team",
    models: [],
    imageGeneration: true,
    imageModels: ["synthetic-image"],
  });
  expect(vi.mocked(api.createKey).mock.calls[0][0].visionInput).not.toBe(true);
  view.unmount();
});

it("edits retained key limits when the current model directory is empty", async () => {
  vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchKeys).mockResolvedValue([key]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: [],
    imageModels: [],
  });
  vi.mocked(api.updateKey).mockResolvedValue({
    ...key,
    revision: 2,
    limits: { ...key.limits, requests: 5 },
  });
  const view = render(<KeyManagement />);
  fireEvent.click(await screen.findByRole("button", { name: "编辑" }));
  expect(screen.getByLabelText("synthetic-text")).toBeChecked();
  fireEvent.click(screen.getByText("本地治理限额"));
  fireEvent.change(screen.getByLabelText("每日请求（UTC）"), {
    target: { value: "5" },
  });
  expect(screen.getByRole("button", { name: "保存修改" })).toBeEnabled();
  fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
  await waitFor(() => expect(api.updateKey).toHaveBeenCalled());
  expect(vi.mocked(api.updateKey).mock.calls[0][3]).toMatchObject({
    requests: 5,
  });
  await waitFor(() =>
    expect(
      screen.queryByRole("button", { name: "保存修改" }),
    ).not.toBeInTheDocument(),
  );
  view.unmount();
});

it("toggles unlimited for each dimension, restores a value and submits explicit nulls", async () => {
  vi.mocked(api.fetchKeys).mockResolvedValue([
    {
      ...key,
      limits: {
        requests: null,
        active: null,
        unresolved: null,
        budgetMicros: null,
        unresolvedMicros: null,
      },
    },
  ]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: ["synthetic-text"],
    imageModels: [],
  });
  vi.mocked(api.updateKey).mockResolvedValue(key);
  const view = render(<KeyManagement />);
  fireEvent.click(await screen.findByRole("button", { name: "编辑" }));
  expect(screen.getByText("不限 / 日")).toBeInTheDocument();
  fireEvent.click(screen.getByText("本地治理限额"));
  for (const label of [
    "每日请求（UTC）",
    "同时执行",
    "待核对请求数量",
    "每日估算阈值（美元）",
    "待核对占用阈值（美元）",
  ]) {
    const toggle = screen.getByLabelText(label + "不限");
    expect(toggle).toBeChecked();
    expect(screen.getByLabelText(label)).toBeDisabled();
    fireEvent.click(toggle);
    expect(screen.getByLabelText(label)).toBeEnabled();
    fireEvent.change(screen.getByLabelText(label), { target: { value: "17" } });
    fireEvent.click(toggle);
    expect(screen.getByLabelText(label)).toBeDisabled();
    fireEvent.click(toggle);
    expect(screen.getByLabelText(label)).toHaveValue("17");
    fireEvent.click(toggle);
  }
  fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
  await waitFor(() => expect(api.updateKey).toHaveBeenCalled());
  expect(vi.mocked(api.updateKey).mock.calls[0][3]).toEqual({
    requests: null,
    active: null,
    unresolved: null,
    budgetMicros: null,
    unresolvedMicros: null,
  });
  view.unmount();
});

it("requires explicit confirmation before disabling, and cancellation leaves the key unchanged", async () => {
  vi.mocked(api.fetchKeys).mockResolvedValue([key]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: ["synthetic-text"],
    imageModels: [],
  });
  vi.mocked(api.updateKey).mockResolvedValue({ ...key, enabled: false });
  render(<KeyManagement />);
  fireEvent.click(await screen.findByRole("button", { name: "team 更多操作" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "禁用" }));
  expect(await screen.findByText(/客户端会立即失败/)).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "取消" }));
  expect(api.updateKey).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "team 更多操作" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "禁用" }));
  fireEvent.click(screen.getByRole("button", { name: "确认禁用" }));
  await waitFor(() => expect(api.updateKey).toHaveBeenCalledOnce());
  expect(vi.mocked(api.updateKey).mock.calls[0][1]).toBe(false);
});

it("retains the editor draft after validation rejection", async () => {
  vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchKeys).mockResolvedValue([key]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: key.models,
    imageModels: [],
  });
  vi.mocked(api.updateKey).mockRejectedValue(
    new api.ManagementError(400, "invalid_request"),
  );
  render(<KeyManagement />);
  fireEvent.click(await screen.findByRole("button", { name: "编辑" }));
  fireEvent.click(screen.getByText("本地治理限额"));
  fireEvent.change(screen.getByLabelText("每日请求（UTC）"), {
    target: { value: "7" },
  });
  fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
  await waitFor(() => expect(api.updateKey).toHaveBeenCalledOnce());
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "保存修改" })).toBeEnabled(),
  );
  expect(screen.getByLabelText("每日请求（UTC）")).toHaveValue("7");
});

it.each([false, true])(
  "sets creation expiration and preserves one-time secret on partial failure=%s",
  async (fails) => {
    vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
    vi.mocked(api.fetchKeys).mockResolvedValue([]);
    vi.mocked(api.fetchOptions).mockResolvedValue({
      models: ["synthetic-text"],
      imageModels: [],
    });
    vi.mocked(api.createKey).mockResolvedValue({
      key: { ...key },
      secret: "synthetic-once",
    });
    if (fails)
      vi.mocked(api.setExpiration).mockRejectedValue(
        new sessions.ManagementError(0, "connection_failed"),
      );
    else
      vi.mocked(api.setExpiration).mockResolvedValue({
        ...key,
        revision: 2,
        expiresAtUnixSeconds: 2000000000,
      });
    render(<KeyManagement />);
    fireEvent.click(await screen.findByRole("button", { name: "创建密钥" }));
    fireEvent.change(screen.getByLabelText("主体标识"), {
      target: { value: "team" },
    });
    fireEvent.click(screen.getByRole("checkbox", { name: "synthetic-text" }));
    fireEvent.change(screen.getByLabelText("到期时间"), {
      target: { value: "7" },
    });
    const date = (screen.getByLabelText("到期日期（UTC）") as HTMLInputElement)
      .value;
    fireEvent.click(
      within(screen.getByRole("dialog", { name: "创建密钥" })).getByRole(
        "button",
        { name: "创建密钥" },
      ),
    );
    await waitFor(() =>
      expect(api.setExpiration).toHaveBeenCalledWith(
        expect.objectContaining({ id: key.id, revision: 1 }),
        Date.parse(date + "T00:00:00Z") / 1000,
        "synthetic-csrf",
        expect.any(AbortSignal),
      ),
    );
    expect(await screen.findByLabelText("新 API Key")).toHaveValue(
      "synthetic-once",
    );
    if (fails)
      expect(await screen.findByText(/密钥已创建但到期设置失败/)).toBeVisible();
    else await screen.findByText("保存一次性凭证");
    expect(api.createKey).toHaveBeenCalledTimes(1);
    expect(vi.mocked(api.createKey).mock.calls[0][0]).not.toHaveProperty(
      "expiresAtUnixSeconds",
    );
  },
);

it("does not revive a dismissed secret when a delayed expiration response arrives", async () => {
  vi.mocked(api.fetchSession).mockResolvedValue({ csrf: "synthetic-csrf" });
  vi.mocked(api.fetchKeys).mockResolvedValue([]);
  vi.mocked(api.fetchOptions).mockResolvedValue({
    models: ["synthetic-text"],
    imageModels: [],
  });
  vi.mocked(api.createKey).mockResolvedValue({
    key: { ...key },
    secret: "synthetic-delayed",
  });
  let finish!: (key: api.ManagedKey) => void;
  vi.mocked(api.setExpiration).mockReturnValue(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  render(<KeyManagement />);
  fireEvent.click(await screen.findByRole("button", { name: "创建密钥" }));
  fireEvent.change(screen.getByLabelText("主体标识"), {
    target: { value: "team" },
  });
  fireEvent.click(screen.getByRole("checkbox", { name: "synthetic-text" }));
  fireEvent.change(screen.getByLabelText("到期时间"), {
    target: { value: "30" },
  });
  fireEvent.click(
    within(screen.getByRole("dialog", { name: "创建密钥" })).getByRole(
      "button",
      { name: "创建密钥" },
    ),
  );
  expect(await screen.findByLabelText("新 API Key")).toHaveValue(
    "synthetic-delayed",
  );
  fireEvent.click(screen.getByRole("button", { name: "我已保存，关闭" }));
  await act(async () => finish({ ...key, revision: 2 }));
  expect(screen.queryByLabelText("新 API Key")).toBeNull();
  expect(api.createKey).toHaveBeenCalledTimes(1);
});
