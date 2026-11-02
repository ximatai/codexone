import { expect, it } from "vitest";
import { screen } from "@testing-library/react";
import type { UseQueryResult } from "@tanstack/react-query";
import { render } from "../../../tests/render";
import { CapacityPanel, fetchHeadroom } from "./CapacityPanel";
it("distinguishes missing, exceeded and zero-threshold values without invalid chart ratios", () => {
  const data = {
    capacities: [
      { name: "daily_requests", current: null, limit: "100", blocking: false },
      {
        name: "daily_estimated_micros",
        current: "20",
        limit: "100",
        blocking: false,
      },
      { name: "rows", current: "200", limit: "0", blocking: false },
    ],
    accounts: [
      {
        id: "synthetic-account",
        current: 20,
        peak24Hours: 24,
        limit: 16,
        blocking: true,
      },
    ],
    unknownReconciliation: {
      count: 0,
      beforeUnixSeconds: 0,
      periodSeconds: 86400,
    },
  };
  render(
    <CapacityPanel
      query={
        { data, isError: false } as UseQueryResult<
          Awaited<ReturnType<typeof fetchHeadroom>>,
          Error
        >
      }
      onRelease={() => {}}
    />,
  );
  expect(screen.getByText("$0.00002 / $0.0001")).toBeVisible();
  expect(screen.getAllByText("比例不可用")).toHaveLength(2);
  expect(screen.getByText("20 / 16")).toBeVisible();
  expect(screen.getByText("待核对 0 条")).toBeVisible();
  expect(screen.queryByRole("button", { name: "核对并释放" })).toBeNull();
  expect(document.body.textContent).not.toMatch(/NaN|Infinity/);
});
