import CodexOneCore
import CodexOneRuntime
import Foundation
import Testing

@testable import CodexOneAdapters

private actor PoolProbe {
  var calls: [ExecutionAdmission] = []
  var preparations = 0
  func called(_ admission: ExecutionAdmission) { calls.append(admission) }
  func prepared() { preparations += 1 }
}
private func poolWait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
  for _ in 0..<500 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ExecutionError.capacity
}
private struct PoolFixture {
  let path: String
  let store: SQLiteExecutionStore
  let credentials: AccountCredentials
  let finalizer: ExecutionFinalizer
  let worker: Task<Void, any Error>
  let gateway: AccountPoolGateway
  static func make(expired: Bool = false) async throws -> Self {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("core.sqlite").path
    let limits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 100)
    let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
    let credentials = AccountCredentials(
      store: store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "6d", count: 32)))
    for id in ["a", "b"] {
      let account = try await credentials.importVerified(
        id: id, namespace: "synthetic/\(id)",
        credential: AccountCredential(
          accessToken: "synthetic-\(id)", refreshToken: "synthetic-refresh-\(id)", idToken: nil,
          expiresAtUnixSeconds: expired ? 1 : 2_000_000_000))
      _ = try await store.setAccountMode(id: id, revision: account.revision, mode: .enabled)
    }
    let key = try await store.createKey(
      id: "key", principal: "p", digest: String(repeating: "b", count: 64),
      policy: KeyPolicy(models: ["synthetic-text"], limits: limits))
    let policy = try AccountPoolPolicy(
      key: key, models: ["synthetic-text"], reservedMicros: 1, policyVersion: "1",
      pricingVersion: "1")
    let finalizer = try ExecutionFinalizer(store: store, capacity: 2)
    let worker = Task { try await finalizer.run() }
    try await poolWait { finalizer.isAccepting }
    return Self(
      path: path, store: store, credentials: credentials, finalizer: finalizer, worker: worker,
      gateway: AccountPoolGateway(
        policy: policy, store: store, credentials: credentials, finalizer: finalizer))
  }
  func close() async throws {
    finalizer.stopAccepting()
    try await worker.value
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}

@Test(.timeLimit(.minutes(1))) func accountPoolGatewayOwnsConcurrentWorkAndDoesNotReplayFailure()
  async throws
{
  let f = try await PoolFixture.make()
  let probe = PoolProbe()
  let held = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let first = Task {
    try await f.gateway.execute(model: "synthetic-text", references: [], requestID: "stable") {
      context, work in
      #expect(work.account.id == context.admission.owner.identity)
      #expect(work.credential.accessToken == "synthetic-\(work.account.id)")
      try await context.bind(.init(type: "response", rawID: "first-response"))
      await probe.called(context.admission)
      for await _ in held.stream { break }
      return .init(
        revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0,
        estimatedMicros: 1, completeness: .complete)
    }
  }
  try await poolWait { await probe.calls.count == 1 }
  await #expect(throws: CancellationError.self) {
    try await f.gateway.execute(model: "synthetic-text", references: [], requestID: "stable") {
      context, work in
      #expect(work.account.id == context.admission.owner.identity)
      await probe.called(context.admission)
      try context.observeUsage(
        .init(
          revision: 1, inputTokens: 2, outputTokens: 0, cachedTokens: 0, images: 0,
          estimatedMicros: 1, completeness: .partial))
      throw CancellationError()
    }
  }
  let calls = await probe.calls
  #expect(calls.count == 2)
  #expect(calls[0].owner.identity != calls[1].owner.identity)
  held.continuation.yield(())
  try await first.value
  try await poolWait { f.finalizer.outstanding == 0 }
  #expect(try await f.store.snapshot(attempt: calls[0].attempt).state == .settled)
  let failed = try await f.store.snapshot(attempt: calls[1].attempt)
  #expect(failed.state == .unknown)
  #expect(failed.usage?.inputTokens == 2)
  try await f.gateway.execute(
    model: "synthetic-text", references: [.init(type: "response", rawID: "first-response")]
  ) { context, _ in
    #expect(context.admission.owner.identity == calls[0].owner.identity)
    #expect(context.admission.accountSnapshot?.continuation == true)
    await probe.called(context.admission)
    return .init(
      revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 0, estimatedMicros: 0,
      completeness: .complete)
  }
  try await f.close()
}

@Test(.timeLimit(.minutes(1)))
func accountPoolReservesCapacityBeforePreparationAndRejectsExpiredWithoutDispatch() async throws {
  let f = try await PoolFixture.make(expired: true)
  let tickets = try [f.finalizer.reserve(), f.finalizer.reserve()]
  let probe = PoolProbe()
  let coordinator = ExecutionCoordinator(store: f.store, finalizer: f.finalizer)
  await #expect(throws: ExecutionError.capacity) {
    try await coordinator.executeAccountPool(
      preparing: {
        await probe.prepared()
        throw ExecutionError.invalidCommand
      }, operation: { _, _ in throw ExecutionError.invalidCommand })
  }
  #expect(await probe.preparations == 0)
  for ticket in tickets { f.finalizer.abandon(ticket) }
  await #expect(throws: AccountDispatchError.refreshRequired) {
    try await f.gateway.execute(model: "synthetic-text", references: []) { context, _ in
      await probe.called(context.admission)
      return nil
    }
  }
  #expect(await probe.calls.isEmpty)
  #expect(f.finalizer.outstanding == 0)
  try await f.close()
}
