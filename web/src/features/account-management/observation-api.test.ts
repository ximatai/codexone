import { describe, expect, it } from "vitest";
import { observationNotice, parseObservability } from "./observation-api";
import { observationFixture } from "./observation.test-data";

describe("upstream observations", () => {
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
    expect(observationNotice(failed)).toContain("失败");
    expect(observationNotice(failed)).not.toContain("已更新");
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
