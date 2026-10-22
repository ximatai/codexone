import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { SystemOverview } from "./SystemOverview";

const fixture = JSON.parse(
  readFileSync(
    resolve(
      process.cwd(),
      "../Tests/CodexOneAdaptersTests/Fixtures/system-status.json",
    ),
    "utf8",
  ),
);
afterEach(() => vi.unstubAllGlobals());

it("shows connection progress then the backend readiness result", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(new Response(JSON.stringify(fixture))),
  );
  render(<SystemOverview />);
  expect(screen.getByRole("status")).toHaveTextContent("正在连接");
  expect(
    await screen.findByRole("heading", { name: "网关尚未就绪" }),
  ).toBeVisible();
  expect(screen.getByText("连接正常")).toBeVisible();
});

it("recovers from a failed fetch after explicit retry", async () => {
  vi.stubGlobal(
    "fetch",
    vi
      .fn()
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValueOnce(new Response(JSON.stringify(fixture))),
  );
  render(<SystemOverview />);
  expect(await screen.findByRole("alert")).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "重新连接" }));
  expect(
    await screen.findByRole("heading", { name: "网关尚未就绪" }),
  ).toBeVisible();
});
