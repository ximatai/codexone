import { fireEvent, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { Link, useLocation } from "react-router";
import { renderPrivate } from "../../tests/render";
import { useManagementSession } from "./session";
import * as management from "./management";
import { ViewMemory, readPage } from "./view-memory";
vi.mock("./management", async (original) => ({
  ...(await original<typeof management>()),
  fetchSession: vi.fn().mockResolvedValue({ csrf: "synthetic-proof" }),
}));
it.each([null, "", "1.5", "-1", "0", "Infinity", "NaN", "9007199254740992"])(
  "rejects malformed page query %s",
  (value) => {
    expect(readPage(value, 6)).toBe(1);
  },
);
it("bounds navigation metadata and retains recently updated entries", () => {
  const memory = new ViewMemory();
  for (let i = 0; i < 32; i++) memory.set(String(i), i);
  memory.set("0", "updated");
  memory.set("32", 32);
  expect(memory.size).toBe(32);
  expect(memory.get("0")).toBe("updated");
  expect(memory.has("1")).toBe(false);
});
it("clears page/target and navigation memory on a cross-route 401 without returning to the initial route", async () => {
  let views!: Map<string, unknown>;
  function Probe() {
    const owner = useManagementSession();
    const location = useLocation();
    views = owner.views;
    return (
      <>
        <p>{location.pathname + location.search}</p>
        <Link to="/usage?page=2&target=synthetic">usage</Link>
        <button
          onClick={() => {
            owner.views.set("usage:synthetic", {
              history: [null, "synthetic-cursor"],
            });
            owner.invalidate();
          }}
        >
          expire
        </button>
      </>
    );
  }
  renderPrivate(<Probe />);
  fireEvent.click(await screen.findByText("usage"));
  await screen.findByText("/usage?page=2&target=synthetic");
  fireEvent.click(screen.getByText("expire"));
  await screen.findByRole("heading", { name: "管理员登录" });
  expect(views.size).toBe(0);
  vi.spyOn(management, "login").mockResolvedValue({
    csrf: "synthetic-new-proof",
  });
  fireEvent.change(screen.getByLabelText("管理员凭证"), {
    target: { value: "synthetic-login" },
  });
  fireEvent.click(screen.getByRole("button", { name: "登录管理台" }));
  await waitFor(() => expect(screen.getByText("/usage")).toBeVisible());
  expect(views.size).toBe(0);
});
