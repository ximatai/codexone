import Testing

@testable import CodexOneAdapters

@Test func controlPermitsBoundKeysAndGlobalOccupancyAndReleaseExactlyOnce() throws {
  let capacity = ControlCapacity()
  var first = try (0..<4).map { _ in try capacity.acquire(key: "synthetic-a") }
  #expect(throws: GatewayProtocolError.self) { try capacity.acquire(key: "synthetic-a") }
  var second = try (0..<4).map { _ in try capacity.acquire(key: "synthetic-b") }
  #expect(throws: GatewayProtocolError.self) { try capacity.acquire(key: "synthetic-c") }
  let released = first.removeLast()
  released.release()
  released.release()
  let replacement = try capacity.acquire(key: "synthetic-c")
  #expect(throws: GatewayProtocolError.self) { try capacity.acquire(key: "synthetic-d") }
  first.removeAll()
  second.removeAll()
  replacement.release()
  let recovered = try (0..<4).map { _ in try capacity.acquire(key: "synthetic-a") }
  #expect(recovered.count == 4)
}

@Test func controlBodyLeasesChargeSmallBodiesAndRecoverAfterBudgetFailure() throws {
  let budget = RequestBodyBudget(capacity: 8)
  let first = budget.lease()
  try first.reserve(5, control: true)
  let second = budget.lease()
  #expect(throws: GatewayProtocolError.self) { try second.reserve(4, control: true) }
  #expect(budget.occupiedBytes == 5)
  first.release()
  first.release()
  try second.reserve(8, control: true)
  #expect(budget.occupiedBytes == 8)
  second.release()
  #expect(budget.occupiedBytes == 0)
}

@Test func controlBodyCannotConsumeOrdinarySmallRequestHeadroom() throws {
  let budget = RequestBodyBudget(capacity: 8, headroomCapacity: 4)
  let control = budget.lease()
  try control.reserve(8, control: true)
  #expect(throws: GatewayProtocolError.self) { try budget.lease().reserve(1, control: true) }
  let ordinary = budget.lease()
  try ordinary.reserve(4)
  #expect(budget.sharedOccupiedBytes == 8)
  #expect(budget.headroomOccupiedBytes == 4)
  #expect(budget.occupiedBytes == 12)
  #expect(throws: GatewayProtocolError.self) { try ordinary.reserve(5, control: true) }
  #expect(budget.occupiedBytes == 12)
  control.release()
  ordinary.release()
  #expect(budget.occupiedBytes == 0)
}
