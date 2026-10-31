import { fireEvent, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { ExpirationEditor } from "./ExpirationEditor";
import type { ManagedKey } from "./api";
it("K06 preserves original seconds even after editing a date and restoring it", () => {
  const original = Date.parse("2026-11-03T12:42:56Z") / 1000;
  const save = vi.fn().mockResolvedValue(true);
  render(
    <ExpirationEditor
      entry={
        { principal: "synthetic", expiresAtUnixSeconds: original } as ManagedKey
      }
      disabled={false}
      save={save}
    />,
  );
  fireEvent.change(screen.getByLabelText("到期日期（UTC）"), {
    target: { value: "2026-11-04" },
  });
  expect(screen.getByText(/到期变更/)).toHaveTextContent(
    "2026-11-04 00:00:00 UTC",
  );
  fireEvent.change(screen.getByLabelText("到期日期（UTC）"), {
    target: { value: "2026-11-03" },
  });
  fireEvent.click(screen.getByRole("button", { name: "保存到期时间" }));
  expect(save).toHaveBeenCalledWith(original);
});
it("K07 warns but permits saving a past instant", () => {
  const save = vi.fn().mockResolvedValue(true);
  render(
    <ExpirationEditor
      entry={
        { principal: "synthetic", expiresAtUnixSeconds: null } as ManagedKey
      }
      disabled={false}
      save={save}
    />,
  );
  fireEvent.change(screen.getByLabelText("到期日期（UTC）"), {
    target: { value: "2020-01-01" },
  });
  expect(
    screen.getByText("所选时间已过去，保存后立即拒绝新请求。"),
  ).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "保存到期时间" }));
  expect(save).toHaveBeenCalledWith(Date.parse("2020-01-01T00:00:00Z") / 1000);
});
