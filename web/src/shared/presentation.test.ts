import { expect, it } from "vitest";
import {
  money,
  dollarsToMicros,
  microsToDollars,
  resetIn,
  states,
  terms,
} from "./presentation";
it("converts micro USD exactly, retaining missing and unlimited semantics", () => {
  expect(money(1000000)).toBe("估算 $1.00");
  expect(money("10000000000000001")).toBe("估算 $10,000,000,000.00");
  expect(money(null)).toBe("不可用");
  expect(money(null, true)).toBe("不限");
  expect(money(0)).toBe("估算 $0.00");
  expect(dollarsToMicros("1.234567")).toBe(1234567);
  expect(microsToDollars(17)).toBe(0.000017);
  for (const value of ["0", "-1", "0.0000001", "1000001", "NaN"])
    expect(() => dollarsToMicros(value)).toThrow();
});
it("maps API terminology and formats relative reset boundaries", () => {
  expect(states.unknown).toBe(terms.pending);
  expect(resetIn(11520, 0)).toBe("3 小时 12 分后重置");
  expect(resetIn(86400, 0)).toBe("1 天后重置");
  expect(resetIn(1, 0)).toBe("1 分后重置");
  expect(resetIn(0, 0)).toContain("已到重置时间");
  expect(resetIn(null)).toBe("重置时间未提供");
});
