import { screen } from "@testing-library/react";
import { expect, it } from "vitest";
import { render } from "../../../tests/render";
import { AvailabilitySummary } from "./AvailabilitySummary";

it("requires a known free eligible account slot and current storage before declaring local readiness", () => {
  const props = {
    ready: true,
    unreadable: false,
    accountCount: 2,
    eligibleIDs: ["a", "b"],
    capacities: [],
    storageAllowed: true,
  };
  const full = [
    { id: "a", current: 2, limit: 2, peak24Hours: 2, blocking: true },
    { id: "b", current: 2, limit: 2, peak24Hours: 2, blocking: true },
  ];
  const view = render(
    <AvailabilitySummary {...props} accountHeadroom={full} />,
  );
  expect(screen.getByText("当前存在接入阻断")).toBeVisible();
  expect(screen.getByText(/均已达到本地并发上限/)).toBeVisible();
  view.rerender(
    <AvailabilitySummary
      {...props}
      accountHeadroom={[{ ...full[0], current: 1 }, full[1]]}
    />,
  );
  expect(screen.getByText("本地准入条件正常")).toBeVisible();
  view.rerender(<AvailabilitySummary {...props} accountHeadroom={[]} />);
  expect(screen.getByText("当前可用性无法确认")).toBeVisible();
  view.rerender(
    <AvailabilitySummary
      {...props}
      accountHeadroom={[{ ...full[0], current: 0 }]}
      unreadable
    />,
  );
  expect(screen.getByText("当前可用性无法确认")).toBeVisible();
  view.rerender(
    <AvailabilitySummary
      {...props}
      accountHeadroom={[{ ...full[0], current: 0 }]}
      storageAllowed={false}
    />,
  );
  expect(screen.getByText(/存储当前暂停准入/)).toBeVisible();
});
