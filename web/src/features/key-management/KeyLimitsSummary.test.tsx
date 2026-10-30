import { render } from "../../../tests/render";
import { screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { KeyLimitsSummary } from "./KeyLimitsSummary";
import { fetchKeys } from "./api";
vi.mock("./api", async (original) => ({
  ...(await original<typeof import("./api")>()),
  fetchKeys: vi.fn(),
}));
it("shows unlimited policy beside usage without changing exposure statistics", async () => {
  vi.mocked(fetchKeys).mockResolvedValue([
    {
      id: "k",
      principal: "p",
      enabled: true,
      revision: 1,
      models: ["synthetic"],
      createdAtUnixSeconds: 1,
      limits: {
        requests: null,
        active: 2,
        unresolved: null,
        budgetMicros: null,
        unresolvedMicros: null,
      },
    },
  ]);
  const view = render(<KeyLimitsSummary keyID="k" />);
  expect(await screen.findByText(/每日请求 不限/)).toHaveTextContent(
    "同时执行 2",
  );
  expect(screen.getByText(/每日请求 不限/)).toHaveTextContent(
    "未结暴露阈值 不限",
  );
  view.unmount();
});

it("rereads the same Key after a successful usage refresh", async () => {
  const key = {
    id: "k",
    principal: "p",
    enabled: true,
    revision: 1,
    models: ["synthetic"],
    createdAtUnixSeconds: 1,
    limits: {
      requests: 10,
      active: 2,
      unresolved: 4,
      budgetMicros: 100,
      unresolvedMicros: 100,
    },
  };
  vi.mocked(fetchKeys)
    .mockResolvedValueOnce([key])
    .mockResolvedValueOnce([
      { ...key, limits: { ...key.limits, requests: null } },
    ]);
  const view = render(<KeyLimitsSummary keyID="k" refresh={1} />);
  await screen.findByText(/每日请求 10/);
  view.rerender(<KeyLimitsSummary keyID="k" refresh={2} />);
  expect(await screen.findByText(/每日请求 不限/)).toBeInTheDocument();
  view.unmount();
});
