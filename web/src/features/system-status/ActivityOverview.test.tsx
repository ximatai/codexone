import { reportFixture } from "../usage/usage.test-data";
import { parseUsage } from "../usage/api";
import { fireEvent, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { renderPrivate } from "../../../tests/render";
import { ActivityOverview } from "./ActivityOverview";
import * as api from "./round2-api";
import * as management from "../../shared/management";
vi.mock("./round2-api", async (original) => ({
  ...(await original<typeof api>()),
  fetchDaily: vi.fn(),
  fetchInFlight: vi.fn(),
  fetchRecent: vi.fn(),
}));
vi.mock("../../shared/management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn(),
}));
afterEach(() => vi.clearAllMocks());
it("reports failed query and permits retry to explicit empty state", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchDaily)
    .mockRejectedValueOnce(new management.ManagementError(400, "invalid_range"))
    .mockResolvedValue([]);
  vi.mocked(api.fetchInFlight).mockResolvedValue([]);
  vi.mocked(api.fetchRecent).mockResolvedValue({ rows: [], truncated: false });
  renderPrivate(<ActivityOverview />);
  expect(await screen.findByRole("alert")).toHaveTextContent("读取失败");
  fireEvent.click(screen.getByRole("button", { name: "刷新请求概览" }));
  expect(await screen.findByText("当前没有进行中的请求。")).toBeVisible();
  expect(screen.getByText("暂无已结束的请求。")).toBeVisible();
});

it("keeps trend evidence accessible and shows principal names instead of key identifiers", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchDaily).mockResolvedValue([
    {
      atUnixSeconds: 1,
      requests: 4,
      succeeded: 3,
      failed: 1,
      cancelled: 0,
      failures: { rate_limited: 1 },
      metrics: {
        inputTokens: null,
        cachedTokens: null,
        outputTokens: null,
        images: null,
        estimatedMicros: null,
      },
    },
  ]);
  vi.mocked(api.fetchInFlight).mockResolvedValue([
    {
      id: "synthetic-flight",
      keyID: "hidden-key-identifier",
      principal: "合成工作站",
      displayName: "工作站别名",
      model: "synthetic-text",
      mode: "generation",
      accountID: null,
      elapsedSeconds: 2,
      hasFirstEvent: false,
    },
  ]);
  vi.mocked(api.fetchRecent).mockResolvedValue({
    rows: [
      {
        ...parseUsage(reportFixture()).rows[0],
        displayName: "最近别名",
        principal: "recent-principal",
      },
    ],
    truncated: false,
  });
  renderPrivate(<ActivityOverview />);
  expect(
    await screen.findByRole("img", { name: "今日请求近 7 天：4" }),
  ).toBeVisible();
  expect(
    screen.getByRole("img", { name: "Token近 7 天：不可用" }),
  ).toBeVisible();
  expect(await screen.findByText("工作站别名")).toBeVisible();
  expect(screen.getByText(/合成工作站/)).toBeVisible();
  expect(screen.queryByText(/hidden-key-identifier/)).toBeNull();
  expect(screen.getByText("等待首事件")).toBeVisible();
  expect(await screen.findByText("最近别名")).toBeVisible();
  expect(screen.queryByText(/object Object/)).toBeNull();
});

it("renders only skeletons in KPI cards before the daily response", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchDaily).mockReturnValue(new Promise(() => {}));
  vi.mocked(api.fetchInFlight).mockResolvedValue([]);
  vi.mocked(api.fetchRecent).mockResolvedValue({ rows: [], truncated: false });
  renderPrivate(<ActivityOverview />);
  const kpis = await screen.findByLabelText("正在读取请求概览…");
  expect(kpis).toHaveAttribute("aria-busy", "true");
  expect(kpis.querySelectorAll(".mantine-Skeleton-root")).toHaveLength(4);
  expect(kpis).not.toHaveTextContent("不可用");
  expect(kpis).not.toHaveTextContent("—");
});
