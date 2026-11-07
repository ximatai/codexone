import { expect, it } from "vitest";
import { availabilityBlocker } from "./availability-blocker";

it("only flags a known service, storage, or concurrency blocker", () => {
  const props = {
    ready: true,
    accountCount: 2,
    eligibleIDs: ["a", "b"],
    capacities: [],
    storageAllowed: true,
  };
  const full = [
    { id: "a", current: 2, limit: 2, peak24Hours: 2, blocking: true },
    { id: "b", current: 2, limit: 2, peak24Hours: 2, blocking: true },
  ];
  expect(
    availabilityBlocker({ ...props, accountHeadroom: full })?.text,
  ).toMatch(/并发名额已满/);
  expect(
    availabilityBlocker({
      ...props,
      accountHeadroom: [{ ...full[0], current: 1 }, full[1]],
    }),
  ).toBeNull();
  expect(availabilityBlocker({ ...props, accountHeadroom: [] })).toBeNull();
  expect(availabilityBlocker({ ...props, ready: false })?.text).toBe(
    "生成服务尚未就绪。",
  );
  expect(
    availabilityBlocker({ ...props, storageAllowed: false })?.text,
  ).toMatch(/存储当前暂停准入/);
});
