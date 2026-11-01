import CodexOneCore
import CodexOneRuntime
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private final class PrimingExecutorProbe: QuotaPrimingExecuting, Sendable {
  let models = ["synthetic-text"]
  var defaultModel: String? { models.first }
  let calls = Mutex(0)
  let cancelled = Mutex(0)
  let blocked = Mutex(false)
  let f: RefreshFixture
  let coordinator: ExecutionCoordinator
  let clock: WallClock
  init(_ f: RefreshFixture, finalizer: ExecutionFinalizer, clock: WallClock) {
    self.f = f
    self.clock = clock
    coordinator = .init(store: f.store, finalizer: finalizer, clock: clock)
  }
  func executePriming(id: String, settings: QuotaPrimingSettings) async throws {
    let work = try await f.app.prepareDispatch(id: id, continuation: false)
    let command = ExecutionAdmission(
      attempt: UUID().uuidString,
      owner: .init(
        principal: QuotaPrimingIdentity.principal, key: QuotaPrimingIdentity.principal,
        namespace: work.account.namespace, identity: id), window: "utc-day-\(clock.utcDay)",
      policyVersion: "1", pricingVersion: "1", reservedMicros: 1, mode: .priming,
      model: settings.model ?? defaultModel, accountSnapshot: work.snapshot)
    try await coordinator.execute(command) { context in
      self.calls.withLock { $0 += 1 }
      do {
        while self.blocked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
      } catch {
        self.cancelled.withLock { $0 += 1 }
        throw error
      }
      return UsageEvidence(
        revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0,
        estimatedMicros: 1, completeness: .complete)
    }
  }
}
private func seedPrimingQuota(_ f: RefreshFixture, id: String, clock: WallClock) async throws {
  let account = try await f.store.accountCredential(id: id).account
  let quota = try SubscriptionQuota(limits: [
    .init(
      id: "codex", allowed: true, limitReached: false,
      primary: .init(
        usedPercent: 0, durationSeconds: 18000, resetsAtUnixSeconds: clock.unixSeconds + 18000,
        resetAfterSeconds: 18000),
      secondary: .init(
        usedPercent: 0, durationSeconds: 604800, resetsAtUnixSeconds: clock.unixSeconds + 604800,
        resetAfterSeconds: 604800))
  ])
  _ = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: clock.unixSeconds, result: .success(quota))
}
@Test(.timeLimit(.minutes(1))) func quotaPrimingOwnerDefaultOffModelRemovalStatesAndSingleRequest()
  async throws
{
  let f = try await RefreshFixture.make(count: 5, clock: testClock)
  let finalizer = try ExecutionFinalizer(store: f.store)
  let executor = PrimingExecutorProbe(f, finalizer: finalizer, clock: testClock)
  let service = QuotaPrimingSupervisor(store: f.store, executor: executor, clock: testClock)
  for account in f.accounts { try await seedPrimingQuota(f, id: account.id, clock: testClock) }
  let owner = Task {
    try await GatewayRuntime(services: [finalizer, service]).run(handleSignals: false)
  }
  do {
    try await awaitRefreshCondition { service.isAccepting && finalizer.isAccepting }
    try await service.cycleAccount(f.accounts[0].id)
    #expect(executor.calls.withLock { $0 } == 0)
    for (index, account) in f.accounts.enumerated() {
      var a = account
      if index != 1 {
        a = try await f.store.setAccountMode(
          id: a.id, revision: a.revision, mode: index == 2 ? .draining : .enabled)
      }
      _ = try await f.store.setQuotaPrimingSettings(
        id: a.id, revision: a.revision,
        settings: .init(enabled: true, model: index == 4 ? "removed-model" : "synthetic-text"))
      if index == 3 {
        let current = try await f.store.accountCredential(id: a.id).account
        _ = try await f.store.beginAccountRefresh(
          id: a.id, revision: current.revision, intent: "synthetic-refresh")
        _ = try await f.store.failAccountRefresh(
          id: a.id, credentialVersion: 1, intent: "synthetic-refresh", authorizationRequired: true)
      }
    }
    for account in f.accounts { try await service.cycleAccount(account.id) }
    for _ in 0..<10 { service.observedQuota(id: f.accounts[0].id) }
    try await service.cycleAccount(f.accounts[0].id)
    #expect(executor.calls.withLock { $0 } == 1)
    let removed = try await f.store.quotaPrimingState(id: f.accounts[4].id)
    #expect(!removed.settings.enabled && removed.attention == "model_removed")
  } catch {
    owner.cancel()
    _ = await owner.result
    await f.close()
    throw error
  }
  owner.cancel()
  _ = await owner.result
  await f.close()
}
@Test(.timeLimit(.minutes(1))) func quotaPrimingShutdownCancelsAndSettlesWithoutReplaying()
  async throws
{
  let f = try await RefreshFixture.make(clock: testClock)
  var a = try await f.store.setAccountMode(id: f.accounts[0].id, revision: 1, mode: .enabled)
  _ = try await f.store.setQuotaPrimingSettings(
    id: a.id, revision: a.revision, settings: .init(enabled: true, model: "synthetic-text"))
  a = try await f.store.accountCredential(id: a.id).account
  try await seedPrimingQuota(f, id: a.id, clock: testClock)
  let finalizer = try ExecutionFinalizer(store: f.store)
  let executor = PrimingExecutorProbe(f, finalizer: finalizer, clock: testClock)
  executor.blocked.withLock { $0 = true }
  let service = QuotaPrimingSupervisor(store: f.store, executor: executor, clock: testClock)
  let owner = Task {
    try await GatewayRuntime(services: [finalizer, service]).run(handleSignals: false)
  }
  try await awaitRefreshCondition { service.isAccepting && finalizer.isAccepting }
  service.observedQuota(id: a.id)
  try await awaitRefreshCondition { executor.calls.withLock { $0 } == 1 }
  owner.cancel()
  _ = await owner.result
  #expect(executor.cancelled.withLock { $0 } == 1)
  #expect(!service.isAccepting)
  let state = try await f.store.quotaPrimingState(id: a.id)
  #expect(state.windows.count == 2 && state.windows.values.allSatisfy(\.awaitingActive))
  #expect(state.lastResult != "success")
  await f.close()
}
