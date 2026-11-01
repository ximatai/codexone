import { act, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { render } from "../../../tests/render";
import { LANRiskBanner } from "./LANRiskBanner";
import { fetchSystemStatus } from "./api";
vi.mock("./api", () => ({ fetchSystemStatus: vi.fn() }));
afterEach(() => vi.resetAllMocks());
it("shows the persistent risk text and documentation for LAN HTTP", async () => {
  vi.mocked(fetchSystemStatus).mockResolvedValue({
    service: "codexone",
    ready: false,
    checks: [],
    transportMode: "lan_http",
  });
  render(<LANRiskBanner />);
  expect(
    await screen.findByRole("alert", { name: "局域网明文风险" }),
  ).toHaveTextContent(
    "局域网 HTTP 模式：管理员秘密、Key 与请求内容在局域网中明文传输",
  );
  expect(screen.getByRole("link", { name: "了解风险" })).toHaveAttribute(
    "href",
    expect.stringContaining("#局域网-http-风险"),
  );
  expect(screen.queryByRole("button")).not.toBeInTheDocument();
});
it.each(["loopback", undefined] as const)(
  "omits the banner for existing mode %s",
  async (transportMode) => {
    vi.mocked(fetchSystemStatus).mockResolvedValue({
      service: "codexone",
      ready: false,
      checks: [],
      transportMode,
    });
    await act(async () => render(<LANRiskBanner />));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  },
);
it("aborts the public status read on unmount", () => {
  vi.mocked(fetchSystemStatus).mockReturnValue(new Promise(() => {}));
  const view = render(<LANRiskBanner />);
  const signal = vi.mocked(fetchSystemStatus).mock.calls[0][0];
  view.unmount();
  expect(signal.aborted).toBe(true);
});
