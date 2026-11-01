import { render } from "../../../tests/render";
import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { useEffect, useState } from "react";
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
  expect(await screen.findAllByText("≥ 10,000,000,000,000,001")).toHaveLength(
    2,
  );
  fireEvent.click(screen.getByText("更多统计与用量证据"));
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
  expect(screen.getByLabelText("当前结果筛选")).toHaveTextContent("全部 Key");
  expect(screen.getByRole("button", { name: "下一页" })).toBeDisabled();
  fireEvent.click(screen.getByText("查询用量"));
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  expect(screen.getByText(/当前结果/)).toHaveTextContent("beta");
  expect(screen.getByText("第 1 页")).toBeVisible();
  expect(screen.getByLabelText("当前结果筛选")).toHaveTextContent("压缩");
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
    keyOptions: [
      { id: "alpha", principal: "synthetic-team", displayName: "用量别名" },
    ],
    models: [],
    failures: [],
  });
  const report = api.parseUsage(reportFixture());
  report.rows[0] = {
    ...report.rows[0],
    principal: "synthetic-team",
    displayName: "用量别名",
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
  expect((await screen.findAllByText("用量别名")).length).toBeGreaterThan(0);
  fireEvent.click(
    (await screen.findAllByRole("button", { name: "查看详情" }))[0],
  );
  expect((await screen.findAllByText("首事件耗时")).at(-1)).toBeVisible();
  expect(screen.getAllByText("12 ms").at(-1)).toBeVisible();
  expect(screen.getAllByText("34 ms").at(-1)).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "复制请求 ID" }));
  await waitFor(() => expect(writeText).toHaveBeenCalled());
  expect(writeText).toHaveBeenCalledWith(report.rows[0].requestID);
  expect(document.querySelector("[data-ui-overlay]")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "关闭" }));
  expect(screen.queryByRole("dialog", { name: "请求详情" })).toBeNull();
  fireEvent.click(screen.getAllByRole("button", { name: "查看详情" })[0]);
  expect(document.querySelector("[data-ui-overlay]")).toBeInTheDocument();
  view.unmount();
  expect(screen.queryByRole("dialog", { name: "请求详情" })).toBeNull();
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

it("shows filtered aggregate latency, request duration columns and complete drawer metrics", async () => {
  setup();
  const report = api.parseUsage(reportFixture());
  report.totals.averageFirstEventMilliseconds = 12.5;
  report.totals.p95FirstEventMilliseconds = 60;
  report.totals.averageTotalMilliseconds = 300;
  report.rows[0].firstEventMilliseconds = 15;
  report.rows[0].totalMilliseconds = 200;
  vi.mocked(api.fetchUsage).mockResolvedValue(report);
  render(
    <UsageOverview selection={null} paused={false} onUnauthorized={vi.fn()} />,
  );
  await screen.findByText("12.5 ms");
  expect(screen.getByText("60 ms")).toBeVisible();
  fireEvent.click(screen.getByText("更多统计与用量证据"));
  expect(screen.getByText("300 ms")).toBeVisible();
  expect(
    screen.getByRole("columnheader", { name: "首事件耗时" }),
  ).toBeVisible();
  expect(screen.getByText("15 ms")).toBeInTheDocument();
  expect(screen.getByText("200 ms")).toBeInTheDocument();
  fireEvent.click(screen.getAllByRole("button", { name: "查看详情" })[0]);
  expect((await screen.findAllByText("缓存 token")).at(-1)).toBeVisible();
  expect(screen.getByText("账号")).toBeVisible();
  expect(screen.getByText(/^用量：/)).toBeVisible();
});

it("derives preset selection only from successfully applied filters", async () => {
  setup();
  render(
    <UsageOverview selection={null} paused={false} onUnauthorized={vi.fn()} />,
  );
  await screen.findByText("第 1 页");
  fireEvent.click(screen.getByRole("button", { name: "最近 7 天" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "最近 7 天" })).toHaveAttribute(
      "aria-pressed",
      "true",
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: "自定义" }));
  expect(screen.getByRole("button", { name: "自定义" })).toHaveAttribute(
    "aria-pressed",
    "false",
  );
  vi.mocked(api.fetchUsage).mockRejectedValueOnce(new Error("synthetic"));
  fireEvent.click(screen.getByRole("button", { name: "最近 30 天" }));
  await screen.findByRole("alert");
  expect(screen.getByRole("button", { name: "最近 7 天" })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  fireEvent.change(screen.getByLabelText("起始日（UTC）"), {
    target: { value: "2026-01-01" },
  });
  fireEvent.change(screen.getByLabelText("结束日（UTC）"), {
    target: { value: "2026-01-02" },
  });
  fireEvent.click(screen.getByRole("button", { name: "查询用量" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "自定义" })).toHaveAttribute(
      "aria-pressed",
      "true",
    ),
  );
});

it("U03 restores only after rows commit, even when a frame precedes the slow render", async () => {
  setup();
  const filters = api.defaults();
  const params = api.usageParameters(filters);
  const memory = new Map<string, unknown>([
    [
      `usage:${JSON.stringify(filters)}:page:1`,
      {
        page: 1,
        history: [null, "synthetic_cursor"],
        scroll: 900,
        window: {
          start: Number(params.get("start")),
          end: Number(params.get("end")),
        },
      },
    ],
  ]);
  let finish!: (value: api.UsageReport) => void;
  vi.mocked(api.fetchUsage).mockReturnValueOnce(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  // Simulate a frame firing before React commits the state updates from the read.
  vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
    callback(0);
    return 1;
  });
  const committed: boolean[] = [];
  const scroll = vi.spyOn(window, "scrollTo").mockImplementation((_x, y) => {
    if (y === 900)
      committed.push(
        !!screen.queryByText("第 2 页") &&
          !!screen.queryByText("request-first"),
      );
  });
  render(
    <UsageOverview
      initialFilters={filters}
      requestedPage={1}
      navigationStore={memory}
      selection={null}
      paused={false}
      onUnauthorized={vi.fn()}
    />,
  );
  await waitFor(() => expect(api.fetchUsage).toHaveBeenCalled());
  fireEvent.scroll(window);
  await act(async () => finish(api.parseUsage(reportFixture())));
  await waitFor(() => expect(scroll).toHaveBeenCalledWith(0, 900));
  expect(committed).toEqual([true]);
  expect(screen.getByText("第 2 页")).toBeVisible();
});

it("U03 falls back explicitly when a restored cursor is rejected", async () => {
  setup();
  const filters = api.defaults();
  const params = api.usageParameters(filters);
  const memory = new Map<string, unknown>([
    [
      `usage:${JSON.stringify(filters)}:page:1`,
      {
        page: 1,
        history: [null, "expired-cursor"],
        scroll: 900,
        window: {
          start: Number(params.get("start")),
          end: Number(params.get("end")),
        },
      },
    ],
  ]);
  vi.mocked(api.fetchUsage).mockRejectedValueOnce(
    new ManagementError(400, "invalid_cursor"),
  );
  render(
    <UsageOverview
      initialFilters={filters}
      requestedPage={1}
      navigationStore={memory}
      selection={null}
      paused={false}
      onUnauthorized={vi.fn()}
    />,
  );
  expect(
    await screen.findByText(
      "原分页已失效，已返回请求明细第一页，请重新核对记录。",
    ),
  ).toBeVisible();
  await screen.findByText("第 1 页");
  expect(api.fetchUsage).toHaveBeenLastCalledWith(
    expect.anything(),
    null,
    expect.any(AbortSignal),
  );
});

it.each([true, false])(
  "P2-2 restores only the matching page snapshot on POP=%s",
  async (restoreView) => {
    setup();
    const filters = api.defaults();
    const memory = new Map<string, unknown>([
      [
        `usage:${JSON.stringify(filters)}:page:0`,
        {
          page: 0,
          history: [null],
          scroll: 210,
          window: { start: 100, end: 200 },
        },
      ],
      [
        `usage:${JSON.stringify(filters)}:page:1`,
        {
          page: 1,
          history: [null, "page-two"],
          scroll: 1900,
          window: { start: 300, end: 400 },
        },
      ],
    ]);
    const scroll = vi.spyOn(window, "scrollTo").mockImplementation(() => {});
    render(
      <UsageOverview
        initialFilters={filters}
        requestedPage={0}
        navigationStore={memory}
        restoreView={restoreView}
        selection={null}
        paused={false}
        onUnauthorized={vi.fn()}
      />,
    );
    await screen.findByText("第 1 页");
    await waitFor(() =>
      expect(scroll).toHaveBeenCalledWith(0, restoreView ? 210 : 0),
    );
    expect(scroll).not.toHaveBeenCalledWith(0, 1900);
    expect(api.fetchUsage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        window: restoreView ? { start: 100, end: 200 } : expect.anything(),
      }),
      null,
      expect.any(AbortSignal),
    );
  },
);

it("P2-2 P2-5 preserves POP scroll through a slow failed restore and retry", async () => {
  setup();
  const filters = api.defaults();
  const memory = new Map<string, unknown>([
    [
      `usage:${JSON.stringify(filters)}:page:1`,
      {
        page: 1,
        history: [null, "synthetic_cursor"],
        scroll: 900,
        window: { start: 100, end: 200 },
      },
    ],
  ]);
  let reject!: (cause: Error) => void;
  vi.mocked(api.fetchUsage).mockReturnValueOnce(
    new Promise((_resolve, failure) => {
      reject = failure;
    }),
  );
  const scroll = vi.spyOn(window, "scrollTo").mockImplementation(() => {});
  render(
    <UsageOverview
      initialFilters={filters}
      requestedPage={1}
      navigationStore={memory}
      selection={null}
      paused={false}
      onUnauthorized={vi.fn()}
    />,
  );
  await waitFor(() => expect(api.fetchUsage).toHaveBeenCalled());
  fireEvent.scroll(window);
  await act(async () => reject(new ManagementError(429, "synthetic_busy")));
  await screen.findByRole("alert");
  fireEvent.scroll(window);
  fireEvent.click(screen.getByRole("button", { name: "重试翻页" }));
  await waitFor(() => expect(scroll).toHaveBeenCalledWith(0, 900));
  expect(screen.getByText("第 2 页")).toBeVisible();
});

// Mirrors UsagePage: onApplied writes filters/page back into the props, but the
// test decides when that URL echo arrives relative to the user's next action.
function EchoingOverview({
  echoes,
  view,
}: {
  echoes: (() => void)[];
  view: { filters: api.UsageFilters; page: number };
}) {
  const [shown, setShown] = useState(view);
  useEffect(() => setShown(view), [view]);
  return (
    <UsageOverview
      initialFilters={shown.filters}
      requestedPage={shown.page}
      selection={null}
      paused={false}
      onUnauthorized={vi.fn()}
      onApplied={(filters, navigation) =>
        echoes.push(() =>
          setShown({ filters: { ...filters }, page: navigation?.page ?? 0 }),
        )
      }
    />
  );
}

it("a late URL echo of the applied view keeps the user's next-page read running", async () => {
  setup();
  const echoes: (() => void)[] = [];
  render(
    <EchoingOverview
      echoes={echoes}
      view={{ filters: api.defaults(), page: 0 }}
    />,
  );
  await screen.findByText("第 1 页");
  act(() => echoes.shift()!());
  // The user applies a new filter; its URL echo is still pending.
  fireEvent.change(screen.getByLabelText("Key 主体"), {
    target: { value: "beta" },
  });
  fireEvent.click(screen.getByRole("button", { name: "查询用量" }));
  await waitFor(() => expect(echoes).toHaveLength(1));
  let finish!: (value: api.UsageReport) => void;
  let signal: AbortSignal | undefined;
  vi.mocked(api.fetchUsage).mockImplementationOnce((_f, _c, owned) => {
    signal = owned;
    return new Promise((resolve) => (finish = resolve));
  });
  fireEvent.click(screen.getByRole("button", { name: "下一页" }));
  await waitFor(() => expect(signal).toBeDefined());
  // The filter's echo lands after the click.
  act(() => echoes.shift()!());
  expect(signal!.aborted).toBe(false);
  await act(async () => finish(api.parseUsage(reportFixture())));
  expect(await screen.findByText("第 2 页")).toBeVisible();
  expect(screen.getByRole("button", { name: "查询用量" })).toBeEnabled();
});

it("navigating back to the shown view retires an in-flight read and clears busy", async () => {
  setup();
  const echoes: (() => void)[] = [];
  const shown = { filters: api.defaults(), page: 0 };
  const view = render(<EchoingOverview echoes={echoes} view={shown} />);
  await screen.findByText("第 1 页");
  act(() => echoes.shift()!());
  let signal: AbortSignal | undefined;
  vi.mocked(api.fetchUsage).mockImplementationOnce((_f, _c, owned) => {
    signal = owned;
    return new Promise(() => {});
  });
  // A route change to another view starts a read; POP back to S before it ends.
  view.rerender(
    <EchoingOverview
      echoes={echoes}
      view={{ filters: { ...shown.filters, key: "beta" }, page: 0 }}
    />,
  );
  await waitFor(() => expect(signal).toBeDefined());
  expect(screen.getByRole("button", { name: "正在查询…" })).toBeDisabled();
  view.rerender(
    <EchoingOverview
      echoes={echoes}
      view={{ filters: { ...shown.filters }, page: 0 }}
    />,
  );
  await waitFor(() => expect(signal!.aborted).toBe(true));
  expect(screen.getByRole("button", { name: "查询用量" })).toBeEnabled();
  expect(screen.getByText("第 1 页")).toBeVisible();
  expect(screen.getByLabelText("Key 主体")).toHaveValue("");
});
