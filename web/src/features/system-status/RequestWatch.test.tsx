import { act, fireEvent, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { RequestWatch } from "./RequestWatch";
import type { FlightRow } from "./round2-api";

const row = (id: string, outcome?: string): FlightRow => ({
  id,
  keyID: "synthetic-key",
  principal: "synthetic-tool",
  model: "synthetic-model",
  mode: "http",
  accountID: null,
  hasFirstEvent: false,
  outcome,
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it("captures a newly observed request, keeps its terminal after it leaves the activity buffer, then expires", () => {
  vi.useFakeTimers();
  const props = {
    active: true,
    keys: [],
    selection: null,
    clearSelection: vi.fn(),
  };
  const old = row("synthetic-existing");
  const view = render(<RequestWatch {...props} rows={[old]} />);
  fireEvent.click(screen.getByRole("button", { name: "关注下一次请求" }));
  expect(screen.queryByText(old.id)).not.toBeInTheDocument();
  const next = row("synthetic-next");
  view.rerender(<RequestWatch {...props} rows={[old, next]} />);
  expect(screen.getByText(next.id)).toBeVisible();
  expect(screen.getByText("等待首个上游事件")).toBeVisible();
  view.rerender(<RequestWatch {...props} rows={[row(next.id, "succeeded")]} />);
  view.rerender(<RequestWatch {...props} active={false} rows={[]} />);
  expect(screen.getByText(next.id)).toBeVisible();
  expect(screen.getByText("成功返回")).toBeVisible();
  expect(
    screen.getByRole("link", { name: "按 Key 查看用量与诊断" }),
  ).toHaveAttribute("href", "/usage?key=synthetic-key&range=24h");
  act(() => vi.advanceTimersByTime(600_001));
  expect(screen.queryByText(next.id)).not.toBeInTheDocument();
  expect(screen.getByRole("status")).toHaveTextContent("页面不再保留");
});

it("bounds waiting, retires interrupted waiting, and never infers success from a missing row", () => {
  vi.useFakeTimers();
  const props = { keys: [], selection: null, clearSelection: vi.fn() };
  const view = render(<RequestWatch {...props} active rows={[]} />);
  fireEvent.click(screen.getByRole("button", { name: "关注下一次请求" }));
  act(() => vi.advanceTimersByTime(120_001));
  expect(screen.getByRole("status")).toHaveTextContent("关注已超时");
  fireEvent.click(screen.getByRole("button", { name: "关注下一次请求" }));
  view.rerender(<RequestWatch {...props} active={false} rows={[]} />);
  expect(screen.getByRole("status")).toHaveTextContent("观察已中断");
  view.rerender(<RequestWatch {...props} active rows={[]} />);
  fireEvent.click(screen.getByRole("button", { name: "关注下一次请求" }));
  view.rerender(
    <RequestWatch {...props} active rows={[row("synthetic-disappeared")]} />,
  );
  view.rerender(<RequestWatch {...props} active rows={[]} />);
  expect(screen.getByText("观察中断，结果尚未确认")).toBeVisible();
  expect(screen.queryByText("成功返回")).not.toBeInTheDocument();
});

it("keeps unknown first-event observation honest and handles LAN clipboard absence", async () => {
  const selected = {
    ...row("synthetic-fixed"),
    accountID: "synthetic-account",
    accountDisplayName: "合成订阅",
    hasFirstEvent: null,
  };
  render(
    <RequestWatch
      active
      rows={[selected]}
      keys={[]}
      selection={{ row: selected, revision: 1 }}
      clearSelection={vi.fn()}
    />,
  );
  expect(screen.getByRole("status")).toHaveTextContent("首事件未观测");
  expect(
    screen.getByRole("link", { name: "订阅账号：合成订阅" }),
  ).toHaveAttribute("href", "/?account=synthetic-account");
  vi.stubGlobal("navigator", { clipboard: undefined });
  fireEvent.click(screen.getByRole("button", { name: "复制请求 ID" }));
  expect(
    await screen.findByText("复制失败，可选中上方请求 ID 手动复制。"),
  ).toBeVisible();
});
