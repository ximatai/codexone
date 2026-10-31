import CodexOneCore
import CodexOneRuntime
import Dispatch
import Foundation
import ServiceLifecycle
import Synchronization
import Testing

@testable import CodexOneAdapters

private struct UnusedObservationRefresh: AccountDispatchRefreshing {
  var isAccepting: Bool { true }
  func refreshForDispatch(account: ManagedAccount) async throws -> ManagedAccount {
    throw AccountRefreshError.unavailable
  }
}
private actor QuotaProviderProbe: AccountQuotaProvider {
  var released: Bool
  var calls = 0
  var active = 0
  var peak = 0
  var cancellations = 0
  init(released: Bool = false) { self.released = released }
  func release() { released = true }
  func observe(_ work: AccountObservationWork) async throws -> SubscriptionQuota {
    calls += 1
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    do {
      while !released { try await Task.sleep(for: .milliseconds(5)) }
      return try .init(limits: [
        .init(id: "codex", allowed: true, limitReached: false, primary: nil, secondary: nil)
      ])
    } catch {
      if error is CancellationError { cancellations += 1 }
      throw error
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func observationAllWaitersCanCancelWithoutCancellingTheOwnedRead() async throws {
  let f = try await RefreshFixture.make()
  let provider = QuotaProviderProbe()
  let observer = try AccountObservationSupervisor(
    store: f.store, application: f.app,
    refresher: UnusedObservationRefresh(), provider: provider)
  let owner = Task { try await GatewayRuntime(services: [observer]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { observer.isAccepting }
    let first = Task { try await observer.observeAccount(id: f.accounts[0].id) }
    let second = Task { try await observer.observeAccount(id: f.accounts[0].id) }
    try await awaitRefreshCondition { (await provider.calls) == 1 && observer.waitingRequests == 2 }
    first.cancel()
    second.cancel()
    _ = await first.result
    _ = await second.result
    #expect(observer.waitingRequests == 0 && observer.outstandingAccounts == 1)
    #expect(await provider.cancellations == 0)
    await provider.release()
    try await awaitRefreshCondition { observer.outstandingAccounts == 0 }
    #expect(try await f.store.quotaObservation(id: f.accounts[0].id).quota?.limits.count == 1)
  } catch {
    owner.cancel()
    _ = await owner.result
    await f.close()
    throw error
  }
  owner.cancel()
  _ = await owner.result
  #expect(observer.outstandingAccounts == 0)
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func observationCapacityAndShutdownBoundAllJobsWaitersAndNetworkWorkers() async throws {
  let f = try await RefreshFixture.make(count: 64)
  let provider = QuotaProviderProbe()
  let observer = try AccountObservationSupervisor(
    store: f.store, application: f.app,
    refresher: UnusedObservationRefresh(), provider: provider)
  let owner = Task { try await GatewayRuntime(services: [observer]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { observer.isAccepting }
    let requests = f.accounts.map { account in
      Task { try await observer.observeAccount(id: account.id) }
    }
    try await awaitRefreshCondition {
      (await provider.active) == 4 && observer.waitingRequests == 64
        && observer.outstandingAccounts == 64
    }
    await #expect(throws: QuotaObservationFailure.capacity) {
      try await observer.observeAccount(id: f.accounts[0].id)
    }
    owner.cancel()
    _ = await owner.result
    for request in requests { _ = await request.result }
    #expect(
      observer.outstandingAccounts == 0 && observer.waitingRequests == 0 && !observer.isAccepting)
    #expect(await provider.active == 0)
    #expect(await provider.peak == 4)
    #expect(await provider.cancellations == 4)
    #expect(try await f.store.listAccounts().allSatisfy { $0.authorization == .ready })
  } catch {
    owner.cancel()
    _ = await owner.result
    await f.close()
    throw error
  }
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func observationJoinsExistingRefreshAndPublishesOnlyTheCurrentCredential() async throws {
  let f = try await RefreshFixture.make()
  let old = try await f.app.prepareObservation(id: f.accounts[0].id)
  var account = try await f.app.reauthorizeVerified(
    id: old.account.id, revision: old.account.revision,
    namespace: old.account.namespace,
    credential: .init(
      accessToken: "synthetic-expired-access",
      refreshToken: old.credential.refreshToken, idToken: nil, expiresAtUnixSeconds: 1))
  account = try await f.store.setAccountMode(
    id: account.id, revision: account.revision, mode: .enabled)
  let refreshProvider = RefreshProviderProbe()
  let refreshing = try AccountRefreshSupervisor(application: f.app, provider: refreshProvider)
  let refreshOwner = Task {
    try await GatewayRuntime(services: [refreshing]).run(handleSignals: false)
  }
  let provider = QuotaProviderProbe(released: true)
  let observer = try AccountObservationSupervisor(
    store: f.store, application: f.app, refresher: refreshing, provider: provider)
  var owner: Task<Void, any Error>?
  do {
    try await awaitRefreshCondition { refreshing.isAccepting }
    let captured = account
    let refresh = Task { try await refreshing.refreshForDispatch(account: captured) }
    try await awaitRefreshCondition { await refreshProvider.counts.calls == 1 }
    owner = Task { try await GatewayRuntime(services: [observer]).run(handleSignals: false) }
    try await awaitRefreshCondition { observer.isAccepting && refreshing.waitingRequests == 2 }
    let observed = Task { try await observer.observeAccount(id: captured.id) }
    await refreshProvider.release()
    _ = try await refresh.value
    #expect(try await observed.value.quota?.limits.count == 1)
    #expect(await refreshProvider.counts.calls == 1)
    #expect(await provider.calls == 1)
    #expect(
      try await f.store.accountCredential(id: captured.id).account.credentialVersion == captured
        .credentialVersion + 1)
  } catch {
    owner?.cancel()
    _ = await owner?.result
    refreshOwner.cancel()
    _ = await refreshOwner.result
    await f.close()
    throw error
  }
  owner?.cancel()
  _ = await owner?.result
  refreshOwner.cancel()
  _ = await refreshOwner.result
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func observationCannotPublishAnOldReadAfterReauthorization() async throws {
  let f = try await RefreshFixture.make()
  let provider = QuotaProviderProbe()
  let observer = try AccountObservationSupervisor(
    store: f.store, application: f.app,
    refresher: UnusedObservationRefresh(), provider: provider)
  let owner = Task { try await GatewayRuntime(services: [observer]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { observer.isAccepting }
    let request = Task { try await observer.observeAccount(id: f.accounts[0].id) }
    try await awaitRefreshCondition { await provider.calls == 1 }
    let old = try await f.app.prepareObservation(id: f.accounts[0].id)
    _ = try await f.app.reauthorizeVerified(
      id: old.account.id, revision: old.account.revision,
      namespace: old.account.namespace, credential: old.credential)
    await provider.release()
    await #expect(throws: ExecutionError.conflict) { try await request.value }
    #expect(try await f.store.quotaObservation(id: old.account.id).quota == nil)
    #expect(await provider.calls == 1 && observer.isAccepting)
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

@Test(.timeLimit(.minutes(1)))
func observationCommitFailureStopsTheOwnerAndReleasesEveryWaiter() async throws {
  let f = try await RefreshFixture.make()
  try await f.store.perform { db in
    try db.exec(
      "CREATE TRIGGER fail_quota BEFORE INSERT ON account_quota BEGIN SELECT RAISE(ABORT,'synthetic'); END"
    )
  }
  let provider = QuotaProviderProbe(released: true)
  let observer = try AccountObservationSupervisor(
    store: f.store, application: f.app,
    refresher: UnusedObservationRefresh(), provider: provider)
  let owner = Task { try await GatewayRuntime(services: [observer]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { observer.isAccepting }
    await #expect(throws: ExecutionError.storageUnavailable) {
      try await observer.observeAccount(id: f.accounts[0].id)
    }
    _ = await owner.result
    #expect(
      !observer.isAccepting && observer.outstandingAccounts == 0 && observer.waitingRequests == 0)
  } catch {
    owner.cancel()
    _ = await owner.result
    await f.close()
    throw error
  }
  await f.close()
}

/// Instrument the real store's capacity rejection; no synthetic scan success replaces SQLite.
private actor ObservationScanStore: AccountObservationStore {
  let base: SQLiteExecutionStore
  var capacityRejections = 0
  init(_ base: SQLiteExecutionStore) { self.base = base }
  func listAccounts(after: String?) async throws -> [ManagedAccount] {
    do { return try await base.listAccounts(after: after) } catch ExecutionError.capacity {
      capacityRejections += 1
      throw ExecutionError.capacity
    }
  }
  func accountCredential(id: String) async throws -> StoredAccountCredential {
    try await base.accountCredential(id: id)
  }
  func quotaObservation(id: String) async throws -> AccountQuotaObservation {
    try await base.quotaObservation(id: id)
  }
  func recordQuotaObservation(
    account: ManagedAccount, atUnixSeconds: Int64,
    result: Result<SubscriptionQuota, QuotaObservationFailure>
  ) async throws -> AccountQuotaObservation {
    try await base.recordQuotaObservation(
      account: account, atUnixSeconds: atUnixSeconds, result: result)
  }
  func createVerifiedAccount(id: String, namespace: String, envelope: String) async throws
    -> ManagedAccount
  {
    try await base.createVerifiedAccount(id: id, namespace: namespace, envelope: envelope)
  }
  func setAccountDisplayName(id: String, revision: Int64, displayName: String?) async throws
    -> ManagedAccount
  {
    try await base.setAccountDisplayName(id: id, revision: revision, displayName: displayName)
  }
  func setAccountMode(id: String, revision: Int64, mode: AccountMode) async throws -> ManagedAccount
  {
    try await base.setAccountMode(id: id, revision: revision, mode: mode)
  }
  func beginAccountRefresh(id: String, revision: Int64, intent: String) async throws
    -> StoredAccountCredential
  {
    try await base.beginAccountRefresh(id: id, revision: revision, intent: intent)
  }
  func finishAccountRefresh(id: String, credentialVersion: Int64, intent: String, envelope: String)
    async throws -> ManagedAccount
  {
    try await base.finishAccountRefresh(
      id: id, credentialVersion: credentialVersion, intent: intent, envelope: envelope)
  }
  func failAccountRefresh(
    id: String, credentialVersion: Int64, intent: String, authorizationRequired: Bool
  ) async throws -> ManagedAccount {
    try await base.failAccountRefresh(
      id: id, credentialVersion: credentialVersion, intent: intent,
      authorizationRequired: authorizationRequired)
  }
  func abandonUncompletedAccountRefresh(id: String, credentialVersion: Int64, intent: String)
    async throws -> ManagedAccount
  {
    try await base.abandonUncompletedAccountRefresh(
      id: id, credentialVersion: credentialVersion, intent: intent)
  }
  func credentialUpdatedAtUnixSeconds(id: String) async throws -> Int64? {
    try await base.credentialUpdatedAtUnixSeconds(id: id)
  }
  func replaceVerifiedAccountCredential(
    id: String, revision: Int64, namespace: String, envelope: String
  ) async throws -> ManagedAccount {
    try await base.replaceVerifiedAccountCredential(
      id: id, revision: revision, namespace: namespace, envelope: envelope)
  }
}
private final class ObservationSibling: Service, Sendable {
  let active = Mutex(false)
  func run() async throws {
    active.withLock { $0 = true }
    defer { active.withLock { $0 = false } }
    try await gracefulShutdown()
  }
}

@Test(.timeLimit(.minutes(1)))
func observationPeriodicScanYieldsToRealQueueCapacityAndResumesWithoutStoppingRuntime() async throws
{
  let f = try await RefreshFixture.make()
  let first = f.accounts[0]
  _ = try await f.store.setAccountMode(id: first.id, revision: first.revision, mode: .enabled)
  let held = DispatchSemaphore(value: 0)
  let rejected = Mutex(0)
  let fillers = (0..<32).map { _ in
    Task {
      do {
        try await f.store.perform { _ in _ = held.wait(timeout: .now() + 10) }
      } catch ExecutionError.capacity { rejected.withLock { $0 += 1 } }
    }
  }
  let provider = QuotaProviderProbe(released: true)
  let scanned = ObservationScanStore(f.store)
  let observer = try AccountObservationSupervisor(
    store: scanned, application: f.app, refresher: UnusedObservationRefresh(), provider: provider,
    intervalMilliseconds: 20)
  let sibling = ObservationSibling()
  var owner: Task<Void, any Error>?
  do {
    try await awaitRefreshCondition { rejected.withLock { $0 == 16 } }
    owner = Task {
      try await GatewayRuntime(services: [sibling, observer]).run(handleSignals: false)
    }
    try await awaitRefreshCondition { await scanned.capacityRejections > 0 }
    #expect(observer.isAccepting && sibling.active.withLock { $0 })
    for _ in 0..<16 { held.signal() }
    for filler in fillers { try await filler.value }
    try await awaitRefreshCondition { await provider.calls > 0 }
    try await awaitRefreshCondition {
      try await f.store.quotaObservation(id: first.id).quota != nil
    }
    #expect(observer.isAccepting && sibling.active.withLock { $0 } && f.store.isAvailable)
  } catch {
    for _ in 0..<16 { held.signal() }
    for filler in fillers { _ = await filler.result }
    owner?.cancel()
    _ = await owner?.result
    await f.close()
    throw error
  }
  owner?.cancel()
  _ = await owner?.result
  #expect(!sibling.active.withLock { $0 })
  await f.close()
}
