import { expect, it } from "vitest";
import { compactCount } from "./overview-format";
it("formats integer magnitudes without rounding across unit boundaries or losing exact input", () => {
  expect(compactCount(0)).toBe("0");
  expect(compactCount(9999)).toBe("9,999");
  expect(compactCount(10000)).toBe("1 万");
  expect(compactCount(99999999)).toBe("9999.99 万");
  expect(compactCount(123456789)).toBe("1.23 亿");
  expect(compactCount("2000000000234")).toBe("2 万亿");
  expect(compactCount("9223372036854775807")).toBe("9223372.03 万亿");
});
