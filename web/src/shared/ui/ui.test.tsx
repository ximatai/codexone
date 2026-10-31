import { fireEvent, screen } from "@testing-library/react";
import { expect, it } from "vitest";
import { render } from "../../../tests/render";
import { DataTable } from "./DataTable";
import { TimeText } from "./TimeText";
import { themeCss } from "../../app/theme";
it("sorts real rows in both directions and supplies narrow-screen labels", () => {
  render(
    <DataTable
      rows={[{ id: "b" }, { id: "a" }]}
      rowKey={(row) => row.id}
      retry={() => {}}
      columns={[
        {
          id: "id",
          title: "标识",
          label: "卡片标识",
          render: (row) => row.id,
          sortValue: (row) => row.id,
        },
      ]}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "标识" }));
  expect(screen.getAllByRole("row")[1]).toHaveTextContent("a");
  expect(screen.getAllByText("卡片标识")).toHaveLength(2);
  fireEvent.click(screen.getByRole("button", { name: "标识 ↑" }));
  expect(screen.getAllByRole("row")[1]).toHaveTextContent("b");
});
it("renders loading, error retry and empty states", () => {
  let retries = 0;
  const props = {
    rows: [] as string[],
    columns: [],
    rowKey: (row: string) => row,
    retry: () => retries++,
  };
  const view = render(<DataTable {...props} loading />);
  expect(screen.getByRole("status")).toHaveTextContent("正在读取");
  view.rerender(<DataTable {...props} error="读取失败" />);
  fireEvent.click(screen.getByRole("button", { name: "重试" }));
  expect(retries).toBe(1);
  view.rerender(<DataTable {...props} />);
  expect(screen.getByText("暂无数据。")).toBeVisible();
});
it("renders local, UTC, relative and unavailable times with full titles", () => {
  const view = render(<TimeText value={1700000000} />);
  expect(
    screen.getByText(
      new Date(1700000000000).toLocaleString("zh-CN", { hour12: false }),
    ),
  ).toHaveAttribute("title", expect.stringContaining("UTC"));
  view.rerender(<TimeText value={1700000000} mode="utc" />);
  expect(screen.getByText("2023-11-14 22:13:20 UTC")).toHaveAttribute(
    "dateTime",
    "2023-11-14T22:13:20.000Z",
  );
  view.rerender(
    <TimeText value={1700000000} mode="relative" now={1700000060000} />,
  );
  expect(screen.getByText("1分钟前")).toBeVisible();
  view.rerender(<TimeText value={null} />);
  expect(screen.getByText("不可用")).toBeVisible();
});
it("generates both static schemes from the primary palette", () => {
  const css = themeCss();
  expect(css).toContain("--mantine-color-green-8: #204c3f");
  expect(css).toContain('[data-mantine-color-scheme="light"]');
  expect(css).toContain('[data-mantine-color-scheme="dark"]');
});
