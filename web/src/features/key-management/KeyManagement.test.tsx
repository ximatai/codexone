import { renderPrivate as render } from "../../../tests/render";
import * as sessions from "../../shared/management";
import { beforeEach } from "vitest";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
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
  const view = render(<KeyManagement />);
  await screen.findByText("尚未创建密钥。");
  fireEvent.click(screen.getByRole("button", { name: "创建密钥" }));
  fireEvent.change(screen.getByLabelText("主体标识"), {
    target: { value: "team" },
  });
  fireEvent.click(screen.getByLabelText("synthetic-text"));
  vi.useFakeTimers();
  await act(async () => {
    fireEvent.click(screen.getByText("创建 API Key"));
  });
  expect(screen.getByLabelText("新 API Key")).toHaveValue(
    "synthetic-one-time-secret",
  );
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
  fireEvent.click(screen.getByText("创建 API Key"));
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
