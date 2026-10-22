import { afterEach, expect, it, vi } from "vitest";
import {
  onUnauthorized,
  request,
  retireManagementRequests,
} from "./management";
afterEach(() => {
  vi.unstubAllGlobals();
  retireManagementRequests();
});
it("retires an old-owner unauthorized response without invalidating the next session", async () => {
  let finish!: (value: Response) => void;
  vi.stubGlobal(
    "fetch",
    vi.fn(
      () =>
        new Promise<Response>((resolve) => {
          finish = resolve;
        }),
    ),
  );
  const unauthorized = vi.fn();
  const unsubscribe = onUnauthorized(unauthorized);
  try {
    const pending = request("/api/keys");
    retireManagementRequests();
    finish(
      new Response(JSON.stringify({ error: { code: "unauthorized" } }), {
        status: 401,
      }),
    );
    await expect(pending).rejects.toMatchObject({ status: 401 });
    expect(unauthorized).not.toHaveBeenCalled();
  } finally {
    unsubscribe();
  }
});
it("clears the current owner even when an unauthorized error body is malformed", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(new Response("not-json", { status: 401 })),
  );
  const unauthorized = vi.fn();
  const unsubscribe = onUnauthorized(unauthorized);
  try {
    await expect(request("/api/keys")).rejects.toMatchObject({ status: 0 });
    expect(unauthorized).toHaveBeenCalledOnce();
  } finally {
    unsubscribe();
  }
});
