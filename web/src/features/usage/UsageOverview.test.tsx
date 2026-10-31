import { render } from "../../../tests/render";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { UsageOverview } from "./UsageOverview";
import * as api from "./api";
import { reportFixture } from "./usage.test-data";
import { ManagementError } from "../../shared/management";
vi.mock("./api", async (original) => ({
  ...(await original<typeof api>()),
  fetchUsage: vi.fn(),
  fetchUsageOptions: vi.fn(),
}));
afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
});
function setup() {
  vi.mocked(api.fetchUsageOptions).mockResolvedValue({
    keys: ["alpha", "beta"],
    models: ["synthetic-text"],
    failures: ["rate_limited"],
  });
  vi.mocked(api.fetchUsage).mockResolvedValue(api.parseUsage(reportFixture()));
}
it("preserves lower-bound evidence and the applied filter on failed reads, then supports retry and cursor navigation", async () => {
  setup();
  const view = render(
    <UsageOverview selection={null} paused={false} onUnauthorized={vi.fn()} />,
  );
  await screen.findByText("≥ 10,000,000,000,000,001");
  expect(screen.getByText(/另有 1 条/)).toBeVisible();
  expect(
    screen.getByText(/待核对占用（预估）（不受其他筛选影响）/),
  ).toHaveTextContent("3 待核对");
  fireEvent.click(screen.getByRole("button", { name: "下一页" }));
  await screen.findByText("第 2 页");
  expect(api.fetchUsage).toHaveBeenLastCalledWith(
    expect.anything(),
    "synthetic_cursor",
    expect.any(AbortSignal),
  );
  fireEvent.change(screen.getByLabelText("执行模式"), {
    target: { value: "compact" },
  });
  fireEvent.change(screen.getByLabelText("Key 主体"), {
    target: { value: "beta" },
  });
  vi.mocked(api.fetchUsage).mockRejectedValueOnce(
    new ManagementError(429, "usage_query_capacity"),
  );
  fireEvent.click(screen.getByText("查询用量"));
  await screen.findByRole("alert");
  expect(screen.getByText(/当前结果/)).toHaveTextContent(
    "全部 Key · 上次成功快照",
  );
  expect(screen.getByLabelText("当前结果筛选")).toHaveTextContent("模式 全部");
  expect(screen.getByRole("button", { name: "下一页" })).toBeDisabled();
  fireEvent.click(screen.getByText("查询用量"));
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  expect(screen.getByText(/当前结果/)).toHaveTextContent("beta");
  expect(screen.getByText("第 1 页")).toBeVisible();
  expect(screen.getByLabelText("当前结果筛选")).toHaveTextContent("模式 压缩");
  view.unmount();
});
it("aborts stale ownership on Key selection, pause and unmount, and clears private data on unauthorized", async () => {
  setup();
  let finish: ((value: api.UsageReport) => void) | undefined;
  let signal: AbortSignal | undefined;
  vi.mocked(api.fetchUsage).mockImplementationOnce(
    (_filters, _cursor, owned) => {
      signal = owned;
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
  );
  const onUnauthorized = vi.fn();
  const view = render(
    <UsageOverview
      selection={null}
      paused={false}
      onUnauthorized={onUnauthorized}
    />,
  );
  await waitFor(() => expect(signal).toBeDefined());
  view.rerender(
    <UsageOverview
      selection={{ keyID: "beta", sequence: 1 }}
      paused={false}
      onUnauthorized={onUnauthorized}
    />,
  );
  await screen.findByText(/当前结果/);
  expect(signal?.aborted).toBe(true);
  await act(async () => {
    finish?.({
      ...api.parseUsage(reportFixture()),
      rows: [
        {
          ...api.parseUsage(reportFixture()).rows[0],
          keyID: "late-private-key",
        },
      ],
    });
  });
  expect(screen.queryByText("late-private-key")).toBeNull();
  view.rerender(
    <UsageOverview
      selection={null}
      paused={true}
      onUnauthorized={onUnauthorized}
    />,
  );
  expect(screen.queryByText("请求明细")).toBeNull();
  vi.mocked(api.fetchUsage).mockRejectedValueOnce(
    new ManagementError(401, "unauthorized"),
  );
  view.rerender(
    <UsageOverview
      selection={null}
      paused={false}
      onUnauthorized={onUnauthorized}
    />,
  );
  await waitFor(() => expect(onUnauthorized).toHaveBeenCalledOnce());
  expect(screen.queryByText("请求明细")).toBeNull();
  view.unmount();
});

it("automatically queries the selected Key, shows principal and durations, and copies the full request ID", async () => {
  setup();
  vi.mocked(api.fetchUsageOptions).mockResolvedValue({
    keys: ["alpha"],
    keyOptions: [{ id: "alpha", principal: "synthetic-team" }],
    models: [],
    failures: [],
  });
  const report = api.parseUsage(reportFixture());
  report.rows[0] = {
    ...report.rows[0],
    principal: "synthetic-team",
    firstEventMilliseconds: 12,
    totalMilliseconds: 34,
  };
  vi.mocked(api.fetchUsage).mockResolvedValue(report);
  const writeText = vi.fn().mockResolvedValue(undefined);
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { writeText },
  });
  const view = render(
    <UsageOverview
      selection={{ keyID: "alpha", sequence: 1 }}
      paused={false}
      onUnauthorized={vi.fn()}
    />,
  );
  await waitFor(() =>
    expect(api.fetchUsage).toHaveBeenCalledWith(
      expect.objectContaining({ key: "alpha" }),
      null,
      expect.any(AbortSignal),
    ),
  );
  fireEvent.click(
    (await screen.findAllByRole("button", { name: "查看详情" }))[0],
  );
  expect(await screen.findByText(/首事件耗时：12 ms/)).toHaveTextContent(
    "总耗时：34 ms",
  );
  fireEvent.click(screen.getByRole("button", { name: "复制请求 ID" }));
  await screen.findByText("已复制请求 ID");
  expect(writeText).toHaveBeenCalledWith(report.rows[0].requestID);
  expect(document.body).toHaveClass("management-overlay-open");
  fireEvent.click(screen.getByRole("button", { name: "关闭" }));
  expect(document.body).not.toHaveClass("management-overlay-open");
  fireEvent.click(screen.getAllByRole("button", { name: "查看详情" })[0]);
  expect(document.body).toHaveClass("management-overlay-open");
  view.unmount();
  expect(document.body).not.toHaveClass("management-overlay-open");
});

it("keeps the completed-hour window through pagination across an hour and renews it on query", async () => {
  setup();
  const now = vi
    .spyOn(Date, "now")
    .mockReturnValue(Date.parse("2026-10-31T10:59:59Z"));
  render(
    <UsageOverview selection={null} paused={false} onUnauthorized={vi.fn()} />,
  );
  await screen.findByText("第 1 页");
  fireEvent.click(screen.getByRole("button", { name: "最近 24 小时" }));
  await waitFor(() =>
    expect(api.fetchUsage).toHaveBeenLastCalledWith(
      expect.objectContaining({ range: "24h" }),
      null,
      expect.any(AbortSignal),
    ),
  );
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "下一页" })).toBeEnabled(),
  );
  const first = api.usageParameters(
    vi.mocked(api.fetchUsage).mock.lastCall![0],
  );
  now.mockReturnValue(Date.parse("2026-10-31T11:00:01Z"));
  fireEvent.click(screen.getByRole("button", { name: "下一页" }));
  await screen.findByText("第 2 页");
  const next = api.usageParameters(
    ...(vi.mocked(api.fetchUsage).mock.lastCall!.slice(0, 2) as [
      api.UsageFilters,
      string | null,
    ]),
  );
  expect(next.get("start")).toBe(first.get("start"));
  expect(next.get("end")).toBe(first.get("end"));
  expect(next.get("after")).toBe("synthetic_cursor");
  fireEvent.click(screen.getByRole("button", { name: "上一页" }));
  await screen.findByText("第 1 页");
  expect(
    api.usageParameters(vi.mocked(api.fetchUsage).mock.lastCall![0]).get("end"),
  ).toBe(first.get("end"));
  fireEvent.click(screen.getByRole("button", { name: "查询用量" }));
  await waitFor(() =>
    expect(
      api
        .usageParameters(vi.mocked(api.fetchUsage).mock.lastCall![0])
        .get("end"),
    ).toBe(String(Date.parse("2026-10-31T11:00:00Z") / 1000)),
  );
});
