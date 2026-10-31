import { expect, it } from "vitest";
import { expirationState, expirationLabel } from "./api";
it("classifies exact expiry and seven-day boundaries without treating missing as expired", () => {
  const now = 1000000;
  expect(expirationState(null, now)).toBe("none");
  expect(expirationState(now, now)).toBe("expired");
  expect(expirationState(now + 7 * 86400, now)).toBe("soon");
  expect(expirationState(now + 7 * 86400 + 1, now)).toBe("active");
  expect(expirationLabel(now, now)).toBe("已到期");
});

it("K05 keeps availability and seven-day expiry independent from disabled/expired switches", async () => {
  const { matchesAvailability } = await import("./api");
  const key = { enabled: true } as import("./api").ManagedKey;
  const now = 1000000;
  expect(
    matchesAvailability(
      { ...key, expiresAtUnixSeconds: now },
      "available",
      now,
    ),
  ).toBe(false);
  expect(
    matchesAvailability({ ...key, expiresAtUnixSeconds: now }, "expired", now),
  ).toBe(true);
  expect(
    matchesAvailability(
      { ...key, enabled: false, expiresAtUnixSeconds: now },
      "expired",
      now,
    ),
  ).toBe(true);
  expect(
    matchesAvailability(
      { ...key, enabled: false, expiresAtUnixSeconds: now },
      "disabled",
      now,
    ),
  ).toBe(false);
  expect(
    matchesAvailability(
      { ...key, expiresAtUnixSeconds: now + 7 * 86400 },
      "expiring",
      now,
    ),
  ).toBe(true);
  expect(
    matchesAvailability(
      { ...key, enabled: false, expiresAtUnixSeconds: now + 1 },
      "expiring",
      now,
    ),
  ).toBe(false);
  expect(
    matchesAvailability(
      { ...key, enabled: false, expiresAtUnixSeconds: now + 1 },
      "disabled",
      now,
    ),
  ).toBe(true);
  expect(
    matchesAvailability(
      { ...key, expiresAtUnixSeconds: null },
      "available",
      now,
    ),
  ).toBe(true);
});
