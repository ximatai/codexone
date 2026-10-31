import { AttentionNavigationObserver } from "../../shared/attention-navigation";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { AttentionPanel } from "./AttentionPanel";
import {
  attentionQueryKey,
  attentionMessage,
  attentionTarget,
  type AttentionItem,
} from "./attention-api";
import { WorkspaceFrame } from "../../app/WorkspaceFrame";
import { useQueryClient } from "@tanstack/react-query";
const item: AttentionItem = {
  kind: "account_requires_auth",
  severity: "critical",
  subjectType: "account",
  subjectID: "synthetic-account",
  subjectName: "合成账号",
  detail: {},
  sinceUnixSeconds: 1,
};
it("shows critical and warning messages with corresponding navigation", () => {
  render(
    <AttentionPanel
      items={[
        item,
        {
          ...item,
          kind: "key_expiring",
          severity: "warning",
          subjectType: "key",
          subjectID: "synthetic-key",
          subjectName: "合成Key",
        },
      ]}
      loading={false}
      error={false}
      retry={() => {}}
    />,
  );
  expect(screen.getByLabelText("紧急事项")).toBeVisible();
  expect(screen.getByLabelText("提醒事项")).toBeVisible();
  expect(
    screen.getByRole("link", { name: /合成账号：账号需要重新授权/ }),
  ).toHaveAttribute("href", "/accounts");
  expect(
    screen.getByRole("link", {
      name: /合成Key：访问密钥已到期或将在 7 天内到期/,
    }),
  ).toHaveAttribute("href", "/keys");
});
it("shows empty only after success and offers retry on failure even with cached data", () => {
  const retry = vi.fn();
  const view = render(
    <AttentionPanel items={[]} loading={false} error={false} retry={retry} />,
  );
  expect(screen.getByText("暂无需要处理的事项")).toBeVisible();
  view.rerender(
    <AttentionPanel items={[]} loading={false} error={true} retry={retry} />,
  );
  expect(screen.queryByText("暂无需要处理的事项")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "重试读取提醒" }));
  expect(retry).toHaveBeenCalledOnce();
});
it("routes system and protocol reminders to relevant detail pages", () => {
  expect(
    attentionTarget({
      ...item,
      subjectType: "system",
      kind: "storage_pressure",
    }),
  ).toBe("/?storage=details");
  expect(
    attentionTarget({
      ...item,
      subjectType: "protocol",
      kind: "client_protocol_extension",
    }),
  ).toBe("/?protocol=details");
  expect(
    attentionTarget({
      ...item,
      subjectType: "system",
      kind: "unresolved_executions",
    }),
  ).toBe("/usage");
});
it("updates the accessible navigation marker from the shared homepage snapshot", async () => {
  function Fixture() {
    const client = useQueryClient();
    return (
      <>
        <button
          onClick={() =>
            client.setQueryData(attentionQueryKey, {
              items: [item],
              generatedAtUnixSeconds: 1,
            })
          }
        >
          critical
        </button>
        <button
          onClick={() =>
            client.setQueryData(attentionQueryKey, {
              items: [{ ...item, severity: "warning" }],
              generatedAtUnixSeconds: 1,
            })
          }
        >
          warning
        </button>
        <WorkspaceFrame>
          <AttentionNavigationObserver />
          content
        </WorkspaceFrame>
      </>
    );
  }
  render(<Fixture />);
  expect(screen.getByRole("link", { name: "服务概览" })).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "critical" }));
  await screen.findByRole("link", { name: "服务概览（有需要处理的事项）" });
  fireEvent.click(screen.getByRole("button", { name: "warning" }));
  await waitFor(() =>
    expect(
      screen.queryByRole("link", { name: "服务概览（有需要处理的事项）" }),
    ).toBeNull(),
  );
});

it("disables release when capacity is occupied without any unknown executions", () => {
  const release = vi.fn();
  render(
    <AttentionPanel
      items={[
        {
          ...item,
          kind: "unresolved_executions",
          subjectType: "system",
          detail: { count: 0, unresolvedCount: 512, limit: 1024 },
        },
      ]}
      loading={false}
      error={false}
      retry={() => {}}
      release={release}
    />,
  );
  const button = screen.getByRole("button", { name: "核对并释放" });
  expect(button).toBeDisabled();
  fireEvent.click(button);
  expect(release).not.toHaveBeenCalled();
});

it.each(["backup_disabled", "backup_stale", "backup_size"] as const)(
  "maps %s to actionable backup text and storage details",
  (kind) => {
    const item: AttentionItem = {
      kind,
      severity: "warning",
      subjectType: "system",
      subjectID: null,
      subjectName: null,
      detail: {},
      sinceUnixSeconds: null,
    };
    expect(attentionTarget(item)).toBe("/?storage=details");
    expect(attentionMessage(item)).toContain("备份");
  },
);
