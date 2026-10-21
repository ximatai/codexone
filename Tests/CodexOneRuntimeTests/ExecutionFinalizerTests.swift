import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

private actor DispatchProbe {
  var count = 0
  func dispatched() { count += 1 }
}
private func path() throws -> String {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("core.sqlite").path
}
private let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 100)
private func command(_ id: String) -> ExecutionAdmission {
  .init(
    attempt: id, owner: .init(principal: "p", key: "k", namespace: "synthetic", identity: "i"),
    window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 10)
}
private func waitFor(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
  for _ in 0..<500 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for supervised work")
  throw ExecutionError.capacity
}

@Test(.timeLimit(.minutes(1)))
func finalizerCapacityIsReservedBeforeDispatchAndDuplicatesDoNotLeak() async throws {
  let dbPath = try path()
  defer {
    try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: dbPath, limits: limits)
  let finalizer = try ExecutionFinalizer(store: store, capacity: 1)
  let worker = Task { try await finalizer.run() }
  try await waitFor { finalizer.isAccepting }
  let ticket = try finalizer.reserve()
  let probe = DispatchProbe()
  let coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  await #expect(throws: ExecutionError.capacity) {
    try await coordinator.execute(command("blocked")) { _ in
      await probe.dispatched()
      return nil
    }
  }
  #expect(await probe.count == 0)
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await store.snapshot(attempt: "blocked")
  }
  try await store.admit(command("a"))
  finalizer.handoff(ticket, finalization: .init(attempt: "a", evidence: nil))
  finalizer.handoff(ticket, finalization: .init(attempt: "a", evidence: nil))
  try await waitFor { finalizer.outstanding == 0 }
  #expect(try await store.snapshot(attempt: "a").state == .unknown)
  finalizer.stopAccepting()
  _ = await worker.result
  await store.close()
}

@Test(.timeLimit(.minutes(1))) func coordinatorErrorsHandoffOnceAndShutdownDrainsReservedWork()
  async throws
{
  let dbPath = try path()
  defer {
    try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: dbPath, limits: limits)
  let finalizer = try ExecutionFinalizer(store: store, capacity: 2)
  let worker = Task { try await finalizer.run() }
  try await waitFor { finalizer.isAccepting }
  let coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  await #expect(throws: CancellationError.self) {
    try await coordinator.execute(command("a")) { context in
      try await context.bind(.init(type: "response", rawID: "r"))
      throw CancellationError()
    }
  }
  let ticket = try finalizer.reserve()
  try await store.admit(command("b"))
  finalizer.stopAccepting()
  #expect(!finalizer.canExecute(ticket))
  finalizer.handoff(ticket, finalization: .init(attempt: "b", evidence: nil))
  try await worker.value
  #expect(finalizer.outstanding == 0)
  #expect(try await store.snapshot(attempt: "a").state == .unknown)
  #expect(try await store.snapshot(attempt: "b").state == .unknown)
  await store.close()
}

@Test(.timeLimit(.minutes(1))) func failedAdmissionNeverDispatchesAndReturnsTicket() async throws {
  let dbPath = try path()
  defer {
    try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: dbPath, limits: limits)
  let finalizer = try ExecutionFinalizer(store: store, capacity: 1)
  let worker = Task { try await finalizer.run() }
  try await waitFor { finalizer.isAccepting }
  try await store.admit(command("a"))
  let probe = DispatchProbe()
  let coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  await #expect(throws: ExecutionError.conflict) {
    try await coordinator.execute(command("a")) { _ in
      await probe.dispatched()
      return nil
    }
  }
  #expect(await probe.count == 0)
  #expect(finalizer.outstanding == 0)
  finalizer.stopAccepting()
  try await worker.value
  await store.close()
}

private final class HeldFailingStore: ExecutionStore, Sendable {
  let base: any ExecutionStore
  let entered: AsyncStream<Void>
  let enteredContinuation: AsyncStream<Void>.Continuation
  let release: AsyncStream<Void>
  let releaseContinuation: AsyncStream<Void>.Continuation
  init(base: any ExecutionStore) {
    self.base = base
    let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    entered = entry.stream
    enteredContinuation = entry.continuation
    let unblock = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    release = unblock.stream
    releaseContinuation = unblock.continuation
  }
  func admit(_ command: ExecutionAdmission) async throws { try await base.admit(command) }
  func bind(attempt: String, object: ObjectBinding) async throws {
    try await base.bind(attempt: attempt, object: object)
  }
  func resolve(principal: String, object: ObjectBinding, namespace: String?) async throws
    -> ExecutionOwner
  {
    try await base.resolve(principal: principal, object: object, namespace: namespace)
  }
  func snapshot(attempt: String) async throws -> ExecutionSnapshot {
    try await base.snapshot(attempt: attempt)
  }
  func finalize(attempt: String, evidence: UsageEvidence?) async throws {
    enteredContinuation.yield(())
    for await _ in release { break }
    throw ExecutionError.storageUnavailable
  }
}

@Test(.timeLimit(.minutes(1)))
func saturatedFinalizerFailureStopsAdmissionWithoutWaitingOnConnection() async throws {
  let dbPath = try path()
  defer {
    try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: dbPath, limits: limits)
  let blocked = HeldFailingStore(base: store)
  let finalizer = try ExecutionFinalizer(store: blocked, capacity: 1)
  let worker = Task { try await finalizer.run() }
  try await waitFor { finalizer.isAccepting }
  let coordinator = ExecutionCoordinator(store: store, finalizer: finalizer)
  await #expect(throws: CancellationError.self) {
    try await coordinator.execute(command("a")) { _ in throw CancellationError() }
  }
  for await _ in blocked.entered { break }
  // The connection owner already returned even though the only finalizer write is blocked.
  #expect(finalizer.outstanding == 1)
  #expect(throws: ExecutionError.capacity) { try finalizer.reserve() }
  blocked.releaseContinuation.yield(())
  await #expect(throws: ExecutionError.storageUnavailable) { try await worker.value }
  #expect(finalizer.hasFailed)
  #expect(finalizer.outstanding == 0)
  #expect(throws: ExecutionError.capacity) { try finalizer.reserve() }
  #expect(try await store.snapshot(attempt: "a").state == .intent)
  await store.close()
  let recovered = try await SQLiteExecutionStore.open(path: dbPath, limits: limits)
  #expect(try await recovered.snapshot(attempt: "a").state == .unknown)
  await recovered.close()
}
