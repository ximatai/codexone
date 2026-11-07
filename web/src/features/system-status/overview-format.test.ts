import { expect, it } from "vitest";
import { compactCount, compactKeyTokens } from "./overview-format";
it("formats integer magnitudes without rounding across unit boundaries or losing exact input", () => {
  expect(compactCount(0)).toBe("0");
  expect(compactCount(9999)).toBe("9,999");
  expect(compactCount(10000)).toBe("1 万");
  expect(compactCount(99999999)).toBe("9999.99 万");
  expect(compactCount(123456789)).toBe("1.23 亿");
  expect(compactCount("2000000000234")).toBe("2 万亿");
  expect(compactCount("9223372036854775807")).toBe("9223372.03 万亿");
});

it("shows Key tokens in hundred millions from ten million onward", () => {
  expect(compactKeyTokens("9999999")).toBe("999.99 万");
  expect(compactKeyTokens("10000000")).toBe("0.1 亿");
  expect(compactKeyTokens("25000000")).toBe("0.25 亿");
  expect(compactKeyTokens("123456789")).toBe("1.23 亿");
});
