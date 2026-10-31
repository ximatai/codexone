import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { beforeEach, expect, it, vi } from "vitest";
import { notifications } from "@mantine/notifications";
import { ManagementError } from "./management";
import { useManagedMutation } from "./useManagedMutation";
const owner = {
  session: { csrf: "synthetic-csrf" },
  generation: 1,
  locked: vi.fn(() => false),
  lock: vi.fn(),
  invalidate: vi.fn(),
};
vi.mock("./session", () => ({ useManagementSession: () => owner }));
vi.mock("@mantine/notifications", () => ({
  notifications: { show: vi.fn(), hide: vi.fn() },
}));
beforeEach(() => {
  vi.clearAllMocks();
  owner.generation = 1;
});
function setup() {
  const client = new QueryClient({
    defaultOptions: { mutations: { retry: false } },
  });
  client.setQueryData(["keys"], ["synthetic-key"]);
  const refresh = vi.fn(async () => true);
  function Wrapper({ children }: { children: ReactNode }) {
    const [value] = useState(client);
    return <QueryClientProvider client={value}>{children}</QueryClientProvider>;
  }
  const hook = renderHook(
    () =>
      useManagedMutation({ scope: "keys", invalidate: [["keys"]], refresh }),
    { wrapper: Wrapper },
  );
  return { ...hook, client, refresh };
}
it("uses session CSRF, notifies, invalidates and keeps one-time responses out of both caches", async () => {
  const { result, client } = setup();
  const response = { secret: "synthetic-one-time-secret" };
  const work = vi.fn(async (csrf: string, signal: AbortSignal) => {
    expect(csrf).toBe(owner.session.csrf);
    expect(signal.aborted).toBe(false);
    void response;
  });
  await act(async () => {
    expect(await result.current.run(work, "保存成功")).toBe(true);
  });
  expect(client.getQueryState(["keys"])?.isInvalidated).toBe(true);
  expect(notifications.show).toHaveBeenCalledWith(
    expect.objectContaining({ message: "保存成功" }),
  );
  expect(JSON.stringify(client.getQueryCache().getAll())).not.toContain(
    response.secret,
  );
  expect(
    JSON.stringify(
      client
        .getMutationCache()
        .getAll()
        .map((item) => item.state),
    ),
  ).not.toContain(response.secret);
});
it("refreshes conflicts exactly once without replaying a mutation", async () => {
  const { result, refresh } = setup();
  const work = vi.fn(async () => {
    throw new ManagementError(409, "conflict");
  });
  await act(async () => {
    expect(await result.current.run(work, "成功")).toBe(false);
  });
  expect(work).toHaveBeenCalledOnce();
  expect(refresh).toHaveBeenCalledOnce();
  expect(notifications.show).toHaveBeenCalledWith(
    expect.objectContaining({ message: "数据已被修改，请确认后重试" }),
  );
});
it("invalidates unauthorized sessions", async () => {
  const { result } = setup();
  await act(async () => {
    await result.current.run(async () => {
      throw new ManagementError(401, "unauthorized");
    }, "成功");
  });
  expect(owner.invalidate).toHaveBeenCalledOnce();
  expect(notifications.show).not.toHaveBeenCalled();
});
it("retains the uncertainty lock on network failures", async () => {
  const { result } = setup();
  await act(async () => {
    await result.current.run(async () => {
      throw new TypeError("synthetic offline");
    }, "成功");
  });
  expect(notifications.show).toHaveBeenCalledWith(
    expect.objectContaining({
      message: expect.stringContaining("无法连接管理服务"),
    }),
  );
  expect(owner.lock).not.toHaveBeenCalledWith("keys", false);
});
for (const reason of ["unmount", "session retirement"]) {
  it(`aborts on ${reason} and ignores late completion`, async () => {
    const { result, unmount, rerender } = setup();
    let resolve!: () => void;
    let signal!: AbortSignal;
    let pending!: Promise<boolean>;
    act(() => {
      pending = result.current.run(async (_, current) => {
        signal = current;
        await new Promise<void>((done) => {
          resolve = done;
        });
      }, "成功");
    });
    await waitFor(() => expect(signal).toBeDefined());
    if (reason === "unmount") unmount();
    else {
      owner.generation++;
      rerender();
    }
    expect(signal.aborted).toBe(true);
    await act(async () => {
      resolve();
      await pending;
    });
    expect(notifications.show).not.toHaveBeenCalled();
    expect(owner.lock).not.toHaveBeenCalledWith("keys", false);
  });
}
