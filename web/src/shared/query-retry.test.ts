import { expect, it } from "vitest";
import { ManagementError } from "./management";
import { busyRetryDelay, retryWhenBusy } from "./query-retry";

const busy = new ManagementError(429, "usage_query_capacity");

it("retries only a busy statistics reader, and only a few times", () => {
  expect(retryWhenBusy(0, busy)).toBe(true);
  expect(retryWhenBusy(3, busy)).toBe(true);
  expect(retryWhenBusy(4, busy)).toBe(false);
  expect(retryWhenBusy(0, new ManagementError(429, "rate_limited"))).toBe(
    false,
  );
  expect(
    retryWhenBusy(0, new ManagementError(503, "usage_query_capacity")),
  ).toBe(false);
  expect(retryWhenBusy(0, new Error("network"))).toBe(false);
});

it("spreads retries so concurrent reads do not collide again", () => {
  expect(busyRetryDelay(0, () => 0)).toBe(200);
  expect(busyRetryDelay(0, () => 1)).toBe(500);
  expect(busyRetryDelay(2, () => 0.5)).toBe(1050);
});
