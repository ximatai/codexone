import { expect, it } from "vitest";
import { accountName, credentialExpiry } from "./account-presentation";
it("uses account display names and stable unnamed fallbacks", () => {
  expect(
    accountName("12345678-abcd", [
      { id: "12345678-abcd", displayName: "合成账号" },
    ]),
  ).toBe("合成账号");
  expect(accountName("12345678-abcd")).toBe("未命名账号 · 12345678");
  expect(accountName("12345678-abcd", [], "直接名称")).toBe("直接名称");
  expect(accountName(null)).toBe("账号未记录");
});
it("shows credential expiry, expired and unavailable values", () => {
  expect(credentialExpiry(1060, 1000000)).toBe("访问凭证约 1 分钟后到期");
  expect(credentialExpiry(4600, 1000000)).toBe("访问凭证约 1 小时后到期");
  expect(credentialExpiry(1000, 1000000)).toBe("访问凭证已到期");
  expect(credentialExpiry(null)).toBe("访问凭证到期时间不可用");
});
