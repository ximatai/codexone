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
