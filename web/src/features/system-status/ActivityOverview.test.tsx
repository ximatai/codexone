import { keyReport } from "../../../tests/usage-reports";
import { dailyReport } from "../../../tests/usage-reports";
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
  fetchKeySummary: vi.fn(),
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
    .mockResolvedValue(dailyReport([]));
  vi.mocked(api.fetchInFlight).mockResolvedValue([]);
  vi.mocked(api.fetchKeySummary).mockResolvedValue(keyReport([]));
  renderPrivate(<ActivityOverview />);
  expect((await screen.findAllByRole("alert"))[0]).toHaveTextContent(
    "读取失败",
  );
  fireEvent.click(screen.getByRole("button", { name: "重试" }));
  expect(await screen.findByText("暂无进行中请求")).toBeVisible();
  expect(screen.getByText("暂无活跃 Key")).toBeVisible();
});

it("keeps trend evidence accessible and shows principal names instead of key identifiers", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchDaily).mockResolvedValue(
    dailyReport([
      {
        atUnixSeconds: 1,
        requests: 4,
        recordedRejections: 3,
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
    ]),
  );
  vi.mocked(api.fetchInFlight).mockResolvedValue([
    {
      id: "synthetic-flight",
      reasoningEffort: "xhigh",
      requestMetadataRecorded: true,
      keyID: "hidden-key-identifier",
      principal: "合成工作站",
      displayName: "工作站别名",
      model: "synthetic-text",
      mode: "generation",
      accountID: "synthetic-account",
      elapsedSeconds: 2,
      hasFirstEvent: false,
    },
    {
      id: "synthetic-unspecified",
      keyID: "synthetic-unset-key",
      principal: "未指定客户端",
      model: "synthetic-text",
      mode: "generation",
      accountID: null,
      reasoningEffort: null,
      requestMetadataRecorded: true,
    },
    {
      id: "synthetic-history",
      keyID: "synthetic-history-key",
      principal: "历史客户端",
      model: "synthetic-text",
      mode: "generation",
      accountID: null,
    },
  ]);
  vi.mocked(api.fetchKeySummary).mockResolvedValue(
    keyReport([
      {
        keyID: "synthetic-key",
        displayName: "汇总别名",
        principal: "synthetic-principal",
        admitted: 10,
        succeeded: 4,
        failed: 2,
        cancelled: 1,
        pending: 3,
        inFlight: 0,
      },
    ]),
  );
  renderPrivate(
    <ActivityOverview
      accounts={[{ id: "synthetic-account", displayName: "活动账号" }]}
    />,
  );
  expect(
    await screen.findByRole("img", { name: "今日已准入近 7 天：4" }),
  ).toBeVisible();
  expect(
    screen.getByRole("img", { name: "Token近 7 天：不可用" }),
  ).toBeVisible();
  expect(screen.getByText("拒绝 3")).toBeVisible();
  expect(await screen.findByText("工作站别名")).toBeVisible();
  expect(screen.queryByText("合成工作站")).toBeNull();
  expect(screen.queryByText(/hidden-key-identifier/)).toBeNull();
  expect(screen.getByText("等待响应")).toBeVisible();
  expect(screen.getByText("极高")).toBeVisible();
  expect(await screen.findByText("汇总别名")).toBeVisible();
  expect(screen.queryByText("最近请求")).toBeNull();
  expect(screen.getByLabelText("结果未明 3")).toBeVisible();
  expect(screen.queryByText(/object Object/)).toBeNull();
  expect(screen.getAllByText(/活动账号/)[0]).toBeVisible();
});

it("renders only skeletons in KPI cards before the daily response", async () => {
  vi.mocked(management.fetchSession).mockResolvedValue({
    csrf: "synthetic-csrf",
  });
  vi.mocked(api.fetchDaily).mockReturnValue(new Promise(() => {}));
  vi.mocked(api.fetchInFlight).mockResolvedValue([]);
  vi.mocked(api.fetchKeySummary).mockResolvedValue(keyReport([]));
  renderPrivate(<ActivityOverview />);
  const kpis = await screen.findByLabelText("正在读取请求概览…");
  expect(kpis).toHaveAttribute("aria-busy", "true");
  expect(kpis.querySelectorAll(".mantine-Skeleton-root")).toHaveLength(4);
  expect(kpis).not.toHaveTextContent("不可用");
  expect(kpis).not.toHaveTextContent("—");
});
