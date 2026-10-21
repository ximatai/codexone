import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fetchSystemStatus, parseSystemStatus } from "./api";

const fixture: unknown = JSON.parse(readFileSync(resolve(process.cwd(), "../Tests/CodexOneAdaptersTests/Fixtures/system-status.json"), "utf8"));

describe("system contract", () => {
  it("accepts the backend's shared fixture", () => {
    expect(parseSystemStatus(fixture).ready).toBe(false);
  });
  it.each([null, {}, { service: "other", ready: false, checks: [] }, { service: "codexone", ready: "true", checks: [] }, { service: "codexone", ready: false, checks: [{ name: "store", ready: "false" }] }])("rejects malformed successful replies", (data) => {
    expect(() => parseSystemStatus(data)).toThrow();
  });
});

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });
it("bounds a stalled response body and permits a fresh retry", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("fetch", vi.fn().mockImplementationOnce((_url, options) =>
    Promise.resolve({ ok: true, json: () => new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(options.signal.reason), { once: true });
    }) })
  ).mockResolvedValueOnce(new Response(JSON.stringify(fixture))));
  // Use a controllable timeout signal rather than relying on browser wall time in unit tests.
  const timer = new AbortController();
  const timeout = vi.spyOn(AbortSignal, "timeout").mockReturnValue(timer.signal);
  const request = fetchSystemStatus(new AbortController().signal);
  const rejected = expect(request).rejects.toThrow();
  await Promise.resolve();
  timer.abort(new DOMException("Timed out", "TimeoutError"));
  await rejected;
  expect(timeout).toHaveBeenCalledWith(10_000);
  timeout.mockRestore();
  expect((await fetchSystemStatus(new AbortController().signal)).ready).toBe(false);
});
