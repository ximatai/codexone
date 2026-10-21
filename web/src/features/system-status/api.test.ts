import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseSystemStatus } from "./api";

const fixture: unknown = JSON.parse(readFileSync(resolve(process.cwd(), "../Tests/CodexOneAdaptersTests/Fixtures/system-status.json"), "utf8"));

describe("system contract", () => {
  it("accepts the backend's shared fixture", () => {
    expect(parseSystemStatus(fixture).ready).toBe(false);
  });
  it.each([null, {}, { service: "other", ready: false, checks: [] }, { service: "codexone", ready: "true", checks: [] }, { service: "codexone", ready: false, checks: [{ name: "store", ready: "false" }] }])("rejects malformed successful replies", (data) => {
    expect(() => parseSystemStatus(data)).toThrow();
  });
});
