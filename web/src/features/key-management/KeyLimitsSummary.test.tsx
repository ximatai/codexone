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
        tokens: null,
        active: 2,
      },
    },
  ]);
  const view = render(<KeyLimitsSummary keyID="k" />);
  expect(await screen.findByText(/每日 Token 上限 不限/)).toHaveTextContent(
    "最大并发 2",
  );
  expect(screen.getByText(/每日 Token 上限 不限/)).toHaveTextContent(
    "最大并发 2",
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
      tokens: 10,
      active: 2,
    },
  };
  vi.mocked(fetchKeys)
    .mockResolvedValueOnce([key])
    .mockResolvedValueOnce([
      { ...key, limits: { ...key.limits, tokens: null } },
    ]);
  const view = render(<KeyLimitsSummary keyID="k" refresh={1} />);
  await screen.findByText(/每日 Token 上限 10/);
  view.rerender(<KeyLimitsSummary keyID="k" refresh={2} />);
  expect(await screen.findByText(/每日 Token 上限 不限/)).toBeInTheDocument();
  view.unmount();
});

it("reads the current policy of an archived Key", async () => {
  vi.mocked(fetchKeys)
    .mockResolvedValueOnce([])
    .mockResolvedValueOnce([
      {
        id: "archived",
        principal: "synthetic",
        revision: 2,
        enabled: false,
        archivedAtUnixSeconds: 100,
        models: null,
        limits: {
          tokens: 17,
          active: null,
        },
        createdAtUnixSeconds: 1,
      },
    ]);
  render(<KeyLimitsSummary keyID="archived" />);
  expect(await screen.findByText(/每日 Token 上限 17/)).toBeInTheDocument();
  expect(fetchKeys).toHaveBeenLastCalledWith(expect.any(AbortSignal), true);
});
