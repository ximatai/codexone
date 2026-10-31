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
  renderPrivate(<ActivityOverview refreshOverview={async () => {}} />);
  expect(await screen.findByRole("alert")).toHaveTextContent("读取失败");
  fireEvent.click(screen.getByRole("button", { name: "刷新请求概览" }));
  expect(await screen.findByText("当前没有进行中的请求。")).toBeVisible();
  expect(screen.getByText("暂无已结束的请求。")).toBeVisible();
});
