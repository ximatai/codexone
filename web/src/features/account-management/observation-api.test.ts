import { describe, expect, it } from "vitest";
import { observationNotice, parseObservability } from "./observation-api";
import { observationFixture } from "./observation.test-data";

describe("upstream observations", () => {
  it("treats a credit-only refresh as a successful observation", () => {
    const raw = observationFixture();
    const quota = { ...raw.quota, state: "unavailable", limits: [] };
    const usageCredits = { balance: "0", unlimited: false };
    const refreshed = parseObservability({
      ...raw,
      quota: { ...quota, usageCredits },
    });
    expect(observationNotice(refreshed)).toEqual({
      text: "积分余额已更新，套餐窗口未提供。",
      warning: false,
    });
    expect(
      observationNotice(parseObservability({ ...raw, quota })).warning,
    ).toBe(true);
    expect(
      observationNotice({
        ...refreshed,
        quota: { ...refreshed.quota, failure: "unavailable" },
      }).warning,
    ).toBe(true);
  });
  it("distinguishes observed zero from unavailable fields and keeps failure evidence", () => {
    const raw = observationFixture();
    const value = parseObservability(raw);
    expect(value.quota.limits[0].primary?.usedPercent).toBe(0);
    expect(value.quota.limits[0].secondary).toBeNull();
    const failed = parseObservability({
      ...raw,
      quota: {
        ...raw.quota,
        failure: "unavailable",
        attemptedAtUnixSeconds: 1100,
      },
    });
    expect(failed.quota.observedAtUnixSeconds).toBe(1000);
    expect(observationNotice(failed).text).toContain("失败");
    expect(observationNotice(failed).warning).toBe(true);
  });
  it("rejects forged freshness and duplicate scope identities", () => {
    const raw = observationFixture();
    expect(() =>
      parseObservability({
        ...raw,
        quota: { ...raw.quota, observedAtUnixSeconds: null },
      }),
    ).toThrow();
    expect(() =>
      parseObservability({
        ...raw,
        quota: {
          ...raw.quota,
          limits: [raw.quota.limits[0], raw.quota.limits[0]],
        },
      }),
    ).toThrow();
    expect(() =>
      parseObservability({
        ...raw,
        quota: {
          ...raw.quota,
          limits: [
            {
              ...raw.quota.limits[0],
              primary: { ...raw.quota.limits[0].primary, usedPercent: -1 },
            },
          ],
        },
      }),
    ).toThrow();
  });
});
it("accepts all 48 configured conversation and image cooldowns without hiding health", () => {
  const raw = observationFixture();
  const cooldowns = Array.from({ length: 48 }, (_, index) => ({
    model: `synthetic-${index}`,
    untilUnixSeconds: 2000,
    failure: "rate_limited",
  }));
  expect(
    parseObservability({
      ...raw,
      health: { ...raw.health, cooldownCount: 48, cooldowns },
    }).health.cooldowns,
  ).toHaveLength(48);
  expect(() =>
    parseObservability({
      ...raw,
      health: {
        ...raw.health,
        cooldownCount: 49,
        cooldowns: [...cooldowns, cooldowns[0]],
      },
    }),
  ).toThrow();
});

it.each([
  [undefined, undefined],
  [{ balance: null, unlimited: false }, undefined],
  [{ balance: "synthetic-invalid", unlimited: false }, undefined],
  [{ balance: "0", unlimited: false }, "0"],
  [
    { balance: "123456789012345678.12345678", unlimited: false },
    "123456789012345678.12345678",
  ],
  [{ balance: null, unlimited: true }, "unlimited"],
])(
  "parses optional usage credits independently of windows",
  (usageCredits, expected) => {
    const raw = observationFixture();
    const value = parseObservability({
      ...raw,
      quota: { ...raw.quota, usageCredits },
    });
    expect(value.quota.usageCredits).toBe(expected);
    expect(value.quota.limits[0].primary?.usedPercent).toBe(0);
  },
);
