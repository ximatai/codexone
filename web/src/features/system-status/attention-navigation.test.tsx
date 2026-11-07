import { AttentionNavigationObserver } from "../../shared/attention-navigation";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import { expect, it } from "vitest";
import { render } from "../../../tests/render";
import { attentionQueryKey, type AttentionItem } from "./attention-api";
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
it("updates the accessible navigation marker from the shared homepage snapshot", async () => {
  function Fixture() {
    const client = useQueryClient();
    return (
      <>
        <button
          onClick={() =>
            client.setQueryData(attentionQueryKey, {
              items: [{ ...item, kind: "backup_stale" }],
              generatedAtUnixSeconds: 1,
            })
          }
        >
          critical
        </button>
        <button
          onClick={() =>
            client.setQueryData(attentionQueryKey, {
              items: [{ ...item, kind: "backup_stale", severity: "warning" }],
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
