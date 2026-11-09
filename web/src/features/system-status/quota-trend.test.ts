import { expect, test } from "vitest";
import { predictQuota, quotaSegments, type QuotaSample } from "./quota-trend";

test("fits recent samples and keeps true zero readings", () => {
  const samples: QuotaSample[] = Array.from({ length: 13 }, (_, i) => [
    3600 + i * 300,
    24 - 2 * i,
  ]);
  const prediction = predictQuota(samples, 1);
  expect(prediction.state).toBe("ready");
  expect(prediction.rate).toBeCloseTo(2 / 300);
  expect(quotaSegments(samples).at(-1)?.at(-1)).toEqual([7200, 0]);
});

test("does not count a long data gap as observed time", () => {
  const samples: QuotaSample[] = [
    [3600, 50],
    [3900, 48],
    [6900, 25],
    [7200, 20],
  ];
  expect(quotaSegments(samples)).toHaveLength(2);
  expect(predictQuota(samples, 1)).toEqual({ state: "coverage" });
});

test("labels a single observed step as coarse and leaves flat readings unpredicted", () => {
  const samples: QuotaSample[] = [
    [5400, 20],
    [6000, 20],
    [6600, 19],
    [7200, 19],
  ];
  const prediction = predictQuota(samples, 1);
  expect(prediction.state).toBe("coarse");
  expect(prediction.rate).toBe(1 / 1800);
  expect(
    predictQuota(
      samples.map(([at]) => [at, 20]),
      1,
    ).state,
  ).toBe("coverage");
});

test("excludes a drop during an observation gap from the estimated speed", () => {
  const samples: QuotaSample[] = Array.from({ length: 33 }, (_, i) => [
    3600 + i * 900,
    100 - i - (i >= 17 ? 40 : 0),
  ]);
  samples.splice(16, 1);
  const prediction = predictQuota(samples, 8);
  expect(prediction.state).toBe("coarse");
  expect(prediction.rate).toBeCloseTo(1 / 900, 8);
});
