import {
  act,
  fireEvent,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { ResetCredits } from "./ResetCredits";
import * as api from "./reset-credits-api";
import type { useAccounts } from "./useAccounts";
vi.mock("./reset-credits-api", async (original) => ({
  ...(await original<typeof api>()),
  fetchResetCredits: vi.fn(),
  fetchResetCreditState: vi.fn(),
  consumeResetCredit: vi.fn(),
  saveResetCreditSettings: vi.fn(),
}));
const account = {
  id: "synthetic-account",
  revision: 1,
  credentialVersion: 1,
  mode: "enabled" as const,
  authorization: "ready" as const,
  createdAtUnixSeconds: 1,
};
const saved: api.ResetCreditState = {
  revision: 1,
  settings: { autoUseBeforeExpiry: false, leadHours: 24 },
  pending: false,
  pendingCreditID: null,
  lastCode: null,
  lastAttemptAt: null,
};
const credit: api.ResetCredit = {
  id: "synthetic-credit",
  type: "future-type",
  status: "available",
  grantedAt: "2026-01-01T00:00:00Z",
  expiresAt: "2030-01-01T00:00:00Z",
  title: "合成重置卡",
  description: "用于合成测试",
};
const list: api.ResetCreditList = {
  credits: [
    credit,
    { ...credit, id: "no-expiry", title: "无到期卡", expiresAt: null },
    { ...credit, id: "unknown", title: "未来状态", status: "future" },
  ],
  availableCount: 2,
  state: saved,
};
afterEach(() => {
  vi.clearAllMocks();
});
function setup(state = saved) {
  vi.mocked(api.fetchResetCreditState).mockResolvedValue(state);
  vi.mocked(api.fetchResetCredits).mockResolvedValue({ ...list, state });
  const notices: string[] = [];
  const mutation: ReturnType<typeof useAccounts>["mutation"] = async (
    work,
    success,
  ) => {
    const result = await work("synthetic-csrf");
    notices.push(typeof success === "string" ? success : success(result).text);
  };
  const view = render(
    <ResetCredits
      account={account}
      disabled={false}
      reloadToken={1}
      mutation={mutation}
      onUnauthorized={vi.fn()}
    />,
  );
  return { ...view, notices };
}
it("lists safe fields including absent expiry and requires explicit credit confirmation", async () => {
  vi.mocked(api.consumeResetCredit).mockResolvedValue("nothing_to_reset");
  const { notices } = setup();
  await screen.findByText(/上次读取可用 2 张/);
  expect(screen.getByText(/上游未提供到期时间/)).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "使用未来状态" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "使用合成重置卡" }));
  const dialog = screen.getByRole("dialog");
  expect(within(dialog).getByText("合成重置卡")).toBeInTheDocument();
  expect(within(dialog).getByText(/到期：/)).toBeInTheDocument();
  expect(api.consumeResetCredit).not.toHaveBeenCalled();
  fireEvent.click(within(dialog).getByRole("button", { name: "取消" }));
  expect(api.consumeResetCredit).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "使用合成重置卡" }));
  fireEvent.click(screen.getByRole("button", { name: "确认使用" }));
  await waitFor(() =>
    expect(api.consumeResetCredit).toHaveBeenCalledWith(
      account.id,
      credit.id,
      "synthetic-csrf",
      undefined,
    ),
  );
  expect(notices).toContain("当前没有可重置的用量，卡未消耗。");
});
it.each([
  "reset",
  "nothing_to_reset",
  "no_credit",
  "already_redeemed",
  "unknown",
] as const)("explains %s in Chinese", async (code) => {
  setup({ ...saved, lastCode: code, pending: code === "unknown" });
  expect(
    await screen.findByText("最近操作：" + api.resetCreditMessage(code)),
  ).toBeInTheDocument();
});
it("pending operations only reconcile the persisted selection through a fresh confirmation", async () => {
  vi.mocked(api.consumeResetCredit).mockResolvedValue("already_redeemed");
  setup({
    ...saved,
    pending: true,
    pendingCreditID: credit.id,
    lastCode: "unknown",
  });
  await screen.findByText(/上次读取可用/);
  expect(screen.getByRole("button", { name: "使用合成重置卡" })).toBeDisabled();
  expect(
    screen.getByRole("button", { name: "由提供者选择一张" }),
  ).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "核对上次操作" }));
  fireEvent.click(screen.getByRole("button", { name: "确认核对" }));
  await waitFor(() =>
    expect(api.consumeResetCredit).toHaveBeenCalledWith(
      account.id,
      undefined,
      "synthetic-csrf",
      undefined,
    ),
  );
});
it("defaults automation off and saves bounded lead hours with the observed revision", async () => {
  vi.mocked(api.saveResetCreditSettings).mockResolvedValue(saved);
  setup();
  await screen.findByText(/上次读取可用/);
  const toggle = screen.getByLabelText("到期前自动使用", { exact: true });
  expect(toggle).not.toBeChecked();
  fireEvent.click(toggle);
  fireEvent.change(screen.getByLabelText("提前小时数"), {
    target: { value: "48" },
  });
  fireEvent.click(screen.getByRole("button", { name: "保存重置卡设置" }));
  await waitFor(() =>
    expect(api.saveResetCreditSettings).toHaveBeenCalledWith(
      account.id,
      1,
      { autoUseBeforeExpiry: true, leadHours: 48 },
      "synthetic-csrf",
      undefined,
    ),
  );
});
it("cancels a pending read and ignores stale results when the details close", async () => {
  let resolve!: (value: api.ResetCreditState) => void;
  const view = setup();
  vi.mocked(api.fetchResetCreditState).mockImplementationOnce(
    () =>
      new Promise((done) => {
        resolve = done;
      }),
  );
  await screen.findByText(/上次读取可用/);
  fireEvent.click(screen.getByRole("button", { name: "重新读取重置卡" }));
  await waitFor(() => expect(resolve).toBeDefined());
  const signal = vi.mocked(api.fetchResetCreditState).mock.calls.at(-1)![1]!;
  view.unmount();
  expect(signal.aborted).toBe(true);
  await act(async () => resolve(saved));
});
