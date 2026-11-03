import { expect, it } from "vitest";
import {
  businessDate,
  businessTime,
  dayStart,
  readBusinessDay,
} from "./business-day";
import { usageParameters, defaults } from "../features/usage/api";
it("uses fixed server dates at both offset boundaries independent of the browser zone", () => {
  const epoch = Date.parse("2026-11-02T16:00:00Z") / 1000;
  expect(businessDate(epoch, 480)).toBe("2026-11-03");
  expect(businessTime(epoch, 480)).toBe("2026-11-03 00:00:00 UTC+08:00");
  expect(dayStart(epoch - 1, 480)).toBe(epoch - 86400);
  expect(dayStart(epoch, 480)).toBe(epoch);
  for (const offsetMinutes of [-720, 0, 480, 840]) {
    const parameters = usageParameters({
      ...defaults(),
      start: "2026-11-03",
      end: "2026-11-03",
      offsetMinutes,
    });
    expect(Number(parameters.get("start"))).toBe(
      Date.parse("2026-11-03T00:00:00Z") / 1000 - offsetMinutes * 60,
    );
    expect(
      Number(parameters.get("end")) - Number(parameters.get("start")),
    ).toBe(86400);
  }
});
it("rejects inconsistent metadata and unsupported offsets", () => {
  for (const offsetMinutes of [-780, 330, 900, 1.5])
    expect(() =>
      readBusinessDay({ businessDay: { offsetMinutes }, timezone: "UTC" }),
    ).toThrow();
  expect(() =>
    readBusinessDay({ businessDay: { offsetMinutes: 480 }, timezone: "UTC" }),
  ).toThrow();
  expect(
    readBusinessDay({
      businessDay: { offsetMinutes: 840 },
      timezone: "UTC+14:00",
    }),
  ).toEqual({ offsetMinutes: 840 });
});
