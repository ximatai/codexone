import { expect, it } from "vitest";
import { screen } from "@testing-library/react";
import { render } from "../../../tests/render";
import { UsageDetail } from "./UsageDetail";
import { reportFixture } from "./usage.test-data";
import { parseUsage, type UsageReport } from "./api";
it.each([true, false])(
  "maps usage detail account names (known=%s)",
  async (known) => {
    const detail = {
      ...reportFixture().rows[0],
      accountID: "12345678-abcd",
    } as UsageReport["rows"][number];
    render(
      <UsageDetail
        detail={detail}
        accounts={
          known ? [{ id: "12345678-abcd", displayName: "明细账号" }] : []
        }
        onClose={() => {}}
      />,
    );
    expect(
      await screen.findByText(known ? "明细账号" : "未命名账号 · 12345678"),
    ).toBeVisible();
  },
);

it.each(["partial", null] as const)(
  "marks retained evidence as lower bounds when completeness is %s",
  async (completeness) => {
    const detail = {
      ...reportFixture().rows[0],
      completeness,
      metrics: {
        ...reportFixture().rows[0].metrics,
        inputTokens: "125",
        outputTokens: null,
        estimatedMicros: "1250000",
      },
    } as UsageReport["rows"][number];
    render(<UsageDetail detail={detail} onClose={() => {}} />);
    expect(
      await screen.findByText("用量：完整用量不可用，已有数值为下界"),
    ).toBeVisible();
    expect(screen.getByText("≥ 125")).toBeVisible();
    expect(screen.getByText("≥ 估算 $1.25")).toBeVisible();
    expect(screen.queryByText("≥ 不可用")).toBeNull();
  },
);
it("keeps complete evidence exact", async () => {
  const detail = {
    ...reportFixture().rows[0],
    metrics: {
      ...reportFixture().rows[0].metrics,
      inputTokens: "125",
      estimatedMicros: "1250000",
    },
  } as UsageReport["rows"][number];
  render(<UsageDetail detail={detail} onClose={() => {}} />);
  expect(await screen.findByText("用量：完整")).toBeVisible();
  expect(screen.getByText("125")).toBeVisible();
  expect(screen.getByText("估算 $1.25")).toBeVisible();
  expect(screen.queryByText("≥ 125")).toBeNull();
});

it("keeps complete SVG counters exact while marking the price as partial", async () => {
  const detail = {
    ...reportFixture().rows[0],
    svgAuthorModel: "synthetic-author",
    usageMissingReasons: ["svg_price_unavailable"],
    metrics: {
      ...reportFixture().rows[0].metrics,
      inputTokens: "125",
      svgInputTokens: "10",
      svgOutputTokens: "20",
      svgReasoningTokens: "5",
      priceCompleteness: "partial",
      estimatedMicros: "1250000",
    },
  } as UsageReport["rows"][number];
  render(<UsageDetail detail={detail} onClose={() => {}} />);
  expect(await screen.findByText("用量：完整")).toBeVisible();
  expect(screen.getByText("125")).toBeVisible();
  expect(screen.getByText("SVG 作者模型：synthetic-author")).toBeVisible();
  expect(screen.getByText("作者费率未知")).toBeVisible();
  expect(screen.getByText("≥ 估算 $1.25")).toBeVisible();
  expect(screen.queryByText("≥ 125")).toBeNull();
});

it("explains a recorded routing rejection without naming an unrecorded account", () => {
  const close = () => {};
  const report = reportFixture();
  const [base] = parseUsage(report).rows;
  const detail = {
    ...base,
    kind: "rejected" as const,
    state: null,
    outcome: null,
    rejectionStage: "routing" as const,
    rejectionReason: "continuation_owner_unavailable",
  };
  const view = render(<UsageDetail detail={detail} onClose={close} />);
  expect(screen.getByText("未派发")).toBeVisible();
  expect(
    screen.getByText("当时无法确认该续接状态所属的账号，未派发请求。"),
  ).toBeVisible();
  view.rerender(
    <UsageDetail
      detail={{ ...detail, rejectionStage: null, rejectionReason: null }}
      onClose={close}
    />,
  );
  expect(screen.queryByText("当时的选路证据")).toBeNull();
  expect(screen.getByText("子原因未记录")).toBeVisible();
});
