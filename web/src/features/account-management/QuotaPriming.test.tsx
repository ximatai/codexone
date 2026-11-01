import { fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { QuotaPriming } from "./QuotaPriming";
import * as api from "./quota-priming-api";
import type { useAccounts } from "./useAccounts";
vi.mock("./quota-priming-api", async (original) => ({
  ...(await original<typeof api>()),
  fetchPriming: vi.fn(),
  savePriming: vi.fn(),
}));
const saved: api.PrimingState = {
  revision: 4,
  settings: { enabled: false, model: null, message: "hello" },
  models: ["synthetic-cheap", "synthetic-other"],
  defaultModel: "synthetic-cheap",
  lastAttemptAt: null,
  lastResult: null,
  attention: null,
};
afterEach(() => vi.clearAllMocks());
function setup(state = saved) {
  vi.mocked(api.fetchPriming).mockResolvedValue(state);
  const mutation: ReturnType<typeof useAccounts>["mutation"] = async (work) => {
    await work("synthetic-csrf");
  };
  return render(
    <QuotaPriming
      account={{
        id: "synthetic-account",
        revision: 4,
        credentialVersion: 1,
        mode: "disabled",
        authorization: "requires_auth",
        createdAtUnixSeconds: 1,
      }}
      disabled={false}
      reloadToken={1}
      mutation={mutation}
      onUnauthorized={vi.fn()}
    />,
  );
}
it("defaults off and saves configured model/message with the account CAS, including disabled accounts", async () => {
  setup();
  await screen.findByText(/尚无预热尝试/);
  expect(screen.getByLabelText("自动预热空闲窗口")).not.toBeChecked();
  expect(screen.getByLabelText("预热模型")).toHaveValue("synthetic-cheap");
  expect(screen.getByText(/合成请求/)).toHaveTextContent(/风控/);
  expect(screen.getByRole("button", { name: "保存预热设置" })).toBeDisabled();
  fireEvent.click(screen.getByLabelText("自动预热空闲窗口"));
  fireEvent.change(screen.getByLabelText("预热模型"), {
    target: { value: "synthetic-other" },
  });
  fireEvent.change(screen.getByLabelText("预热消息"), {
    target: { value: "你好" },
  });
  expect(screen.getByText("2 / 200 字符")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "保存预热设置" }));
  await waitFor(() =>
    expect(api.savePriming).toHaveBeenCalledWith(
      "synthetic-account",
      4,
      { enabled: true, model: "synthetic-other", message: "你好" },
      "synthetic-csrf",
      undefined,
    ),
  );
});
it.each(["", "a".repeat(201), "line\nbreak", "a\u200bb"])(
  "blocks invalid message %j",
  async (message) => {
    setup();
    await screen.findByText(/尚无预热尝试/);
    fireEvent.change(screen.getByLabelText("预热消息"), {
      target: { value: message },
    });
    expect(screen.getByRole("button", { name: "保存预热设置" })).toBeDisabled();
  },
);
it("counts Unicode scalars and accepts the exact upper bound as plain text", () => {
  expect(api.validPrimingMessage("😀".repeat(200))).toBe(true);
  expect(api.validPrimingMessage("<b>hello</b>")).toBe(true);
});
it("requires a replacement for a removed model and shows last result", async () => {
  setup({
    ...saved,
    settings: { ...saved.settings, model: "removed" },
    lastAttemptAt: 1_800_000_000,
    lastResult: "unknown",
    attention: "model_removed",
  });
  await screen.findByText(/所选模型已移除/);
  expect(screen.getByText(/失败或结果未知/)).toBeInTheDocument();
  fireEvent.click(screen.getByLabelText("自动预热空闲窗口"));
  expect(screen.getByRole("button", { name: "保存预热设置" })).toBeDisabled();
  fireEvent.change(screen.getByLabelText("预热模型"), {
    target: { value: "synthetic-cheap" },
  });
  expect(screen.getByRole("button", { name: "保存预热设置" })).toBeEnabled();
});
it("fails visibly and keeps saving blocked when the state cannot be read", async () => {
  setup();
  vi.mocked(api.fetchPriming).mockRejectedValue(new Error("synthetic"));
  fireEvent.click(
    await screen.findByRole("button", { name: "重新读取预热设置" }),
  );
  await screen.findByText(/预热设置读取失败/);
  expect(screen.getByRole("button", { name: "保存预热设置" })).toBeDisabled();
});
