import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { AccountObservability } from "./AccountObservability";
import * as api from "./observation-api";
import { observationFixture } from "./observation.test-data";
vi.mock("./observation-api", async () => ({
  ...(await vi.importActual<typeof api>("./observation-api")),
  fetchObservation: vi.fn(),
}));
afterEach(() => vi.clearAllMocks());
const account = {
  id: "synthetic-account",
  revision: 1,
  credentialVersion: 1,
  mode: "disabled" as const,
  authorization: "ready" as const,
  createdAtUnixSeconds: 1000,
};
it("blocks passive reading after detail failure until a successful retry", async () => {
  vi.mocked(api.fetchObservation)
    .mockRejectedValueOnce(new Error())
    .mockResolvedValue(api.parseObservability(observationFixture()));
  render(
    <AccountObservability
      account={account}
      now={performance.now()}
      disabled={false}
      onObserve={vi.fn()}
      onUnauthorized={vi.fn()}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  await screen.findByRole("alert");
  expect(screen.getByRole("button", { name: "读取上游额度" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "重试详情" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "读取上游额度" })).toBeEnabled(),
  );
  expect(screen.getByText("已用 0% · 剩余 100%")).toBeVisible();
  expect(screen.getByText("上游未提供")).toBeVisible();
});
it("ignores a late detail response after its account is removed", async () => {
  let finish!: (value: api.AccountObservability) => void;
  vi.mocked(api.fetchObservation).mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const view = render(
    <AccountObservability
      account={account}
      now={performance.now()}
      disabled={false}
      onObserve={vi.fn()}
      onUnauthorized={vi.fn()}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  view.unmount();
  await act(async () => finish(api.parseObservability(observationFixture())));
  expect(screen.queryByText("已用 0% · 剩余 100%")).not.toBeInTheDocument();
});

it("returns expired detail reads to the page authentication owner", async () => {
  const onUnauthorized = vi.fn();
  vi.mocked(api.fetchObservation).mockRejectedValueOnce(
    new (await import("../../shared/management")).ManagementError(
      401,
      "unauthorized",
    ),
  );
  render(
    <AccountObservability
      account={account}
      now={performance.now()}
      disabled={false}
      onObserve={vi.fn()}
      onUnauthorized={onUnauthorized}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  await waitFor(() => expect(onUnauthorized).toHaveBeenCalledOnce());
  expect(screen.queryByRole("alert")).toBeNull();
});

it("explains allowed/reached flags even when all percentages are absent", async () => {
  const fixture = observationFixture();
  const limit = {
    id: "codex",
    allowed: false,
    limitReached: true,
    primary: null,
    secondary: null,
  };
  vi.mocked(api.fetchObservation).mockResolvedValueOnce(
    api.parseObservability({
      ...fixture,
      quota: {
        ...fixture.quota,
        limits: [
          limit,
          {
            ...limit,
            id: "synthetic-extra",
            allowed: null,
            limitReached: null,
          },
        ],
        additionalCount: 1,
      },
    }),
  );
  render(
    <AccountObservability
      account={account}
      now={performance.now()}
      disabled={false}
      onObserve={vi.fn()}
      onUnauthorized={vi.fn()}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "额度与健康详情" }));
  await screen.findByText("上游允许使用：否 · 已达窗口限额：是");
  expect(screen.getByText("上游额度报告受限，请查看窗口详情")).toBeVisible();
  expect(
    screen.getByText("上游允许使用：未提供 · 已达窗口限额：未提供"),
  ).toBeVisible();
  expect(screen.getAllByText("上游未提供")).toHaveLength(4);
});
