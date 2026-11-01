import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import ServiceLifecycle
import Testing

actor RefreshProviderProbe: AccountRefreshProvider {
  private let failAfterRelease: Bool
  private let namespaceOverride: String?
  init(failAfterRelease: Bool = false, namespaceOverride: String? = nil) {
    self.failAfterRelease = failAfterRelease
    self.namespaceOverride = namespaceOverride
  }
  private var released = false
  private var calls = 0
  private var active = 0
  private var peak = 0
  private var cancellations = 0
  var counts: (calls: Int, active: Int, peak: Int, cancellations: Int) {
    (calls, active, peak, cancellations)
  }
  func release() { released = true }
  func refresh(credential: AccountCredential, namespace: String) async throws
    -> VerifiedAccountRefresh
  {
    calls += 1
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    do {
      while !released { try await Task.sleep(for: .milliseconds(5)) }
      if failAfterRelease { throw SyntheticProviderFailure() }
      return try VerifiedAccountRefresh(
        namespace: namespaceOverride ?? namespace,
        credential: .init(
          accessToken: "synthetic-new-access", refreshToken: "synthetic-new-refresh", idToken: nil,
          expiresAtUnixSeconds: 2_000_000_000))
    } catch {
      if error is CancellationError { cancellations += 1 }
      throw error
    }
  }
}
struct RefreshFixture {
  let root: URL
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  let accounts: [ManagedAccount]
  static func make(count: Int = 1, clock: WallClock = .system) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let key = root.appendingPathComponent("master")
    try Data(String(repeating: "5a", count: 32).utf8).write(to: key)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    let cipher = try await AccountCredentialCipher.load(path: key.path)
    let store = try await SQLiteExecutionStore.open(
      path: root.appendingPathComponent("core.sqlite").path,
      limits: .init(requests: 100, active: 4, unresolved: 4, budgetMicros: 100), clock: clock)
    let app = AccountCredentials(store: store, protection: cipher, clock: clock)
    var accounts: [ManagedAccount] = []
    for index in 0..<count {
      accounts.append(
        try await app.importVerified(
          id: "account-" + String(index), namespace: "synthetic/account-" + String(index),
          credential: .init(
            accessToken: "synthetic-old-access", refreshToken: "synthetic-old-refresh",
            idToken: nil, expiresAtUnixSeconds: 2_000_000_000)))
    }
    return Self(root: root, store: store, app: app, accounts: accounts)
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(at: root)
  }
}
func awaitRefreshCondition(_ predicate: @Sendable () async throws -> Bool) async throws {
  for _ in 0..<500 {
    if try await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for owned refresh work")
  throw AccountRefreshError.unavailable
}

@Test(.timeLimit(.minutes(1))) func sharedRefreshSurvivesOneOrAllWaitingRequestsCancelling()
  async throws
{
  for cancelAll in [false, true] {
    let fixture = try await RefreshFixture.make()
    let provider = RefreshProviderProbe()
    let service = try AccountRefreshSupervisor(application: fixture.app, provider: provider)
    let owner = Task { try await service.run() }
    defer { owner.cancel() }
    try await awaitRefreshCondition { service.isAccepting }
    let account = fixture.accounts[0]
    let first = Task {
      try await service.refreshAccount(id: account.id, revision: account.revision)
    }
    try await awaitRefreshCondition { await provider.counts.calls == 1 }
    let second = Task {
      try await service.refreshAccount(id: account.id, revision: account.revision)
    }
    try await awaitRefreshCondition { service.waitingRequests == 2 }
    first.cancel()
    await #expect(throws: AccountRefreshError.closed) { try await first.value }
    if cancelAll {
      second.cancel()
      await #expect(throws: AccountRefreshError.closed) { try await second.value }
    } else {
      let churn = (0..<64).map { _ in
        let request = Task {
          try await service.refreshAccount(id: account.id, revision: account.revision)
        }
        request.cancel()
        return request
      }
      for request in churn { _ = await request.result }
    }
    try await awaitRefreshCondition { service.waitingRequests == (cancelAll ? 0 : 1) }
    #expect(await provider.counts.active == 1)
    #expect(service.outstandingIdentities == 1)
    await provider.release()
    if !cancelAll { #expect(try await second.value.credentialVersion == 2) }
    try await awaitRefreshCondition { service.outstandingIdentities == 0 }
    let finished = try await fixture.store.accountCredential(id: account.id).account
    #expect(finished.authorization == .ready && finished.credentialVersion == 2)
    let counts = await provider.counts
    #expect(counts.calls == 1 && counts.cancellations == 0)
    service.stopAccepting()
    try await owner.value
    #expect(service.waitingRequests == 0)
    await fixture.close()
  }
}

@Test(.timeLimit(.minutes(1))) func refreshQueueAndWaiterCapacityRejectBeforeProviderDispatch()
  async throws
{
  let fixture = try await RefreshFixture.make(count: 3)
  let provider = RefreshProviderProbe()
  let service = try AccountRefreshSupervisor(
    application: fixture.app, provider: provider,
    identities: 2, maximumWaiters: 3, perIdentity: 2, parallelism: 1)
  await #expect(throws: AccountRefreshError.closed) {
    try await service.refreshAccount(id: "account-0", revision: 1)
  }
  let owner = Task { try await service.run() }
  defer { owner.cancel() }
  try await awaitRefreshCondition { service.isAccepting }
  let first = Task { try await service.refreshAccount(id: "account-0", revision: 1) }
  try await awaitRefreshCondition { await provider.counts.calls == 1 }
  let second = Task { try await service.refreshAccount(id: "account-0", revision: 1) }
  try await awaitRefreshCondition { service.waitingRequests == 2 }
  await #expect(throws: AccountRefreshError.capacity) {
    try await service.refreshAccount(id: "account-0", revision: 1)
  }
  let queued = Task { try await service.refreshAccount(id: "account-1", revision: 1) }
  try await awaitRefreshCondition { service.waitingRequests == 3 }
  await #expect(throws: AccountRefreshError.capacity) {
    try await service.refreshAccount(id: "account-2", revision: 1)
  }
  second.cancel()
  _ = await second.result
  await #expect(throws: AccountRefreshError.capacity) {
    try await service.refreshAccount(id: "account-2", revision: 1)
  }
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.refreshAccount(id: "account-0", revision: 2)
  }
  #expect(await provider.counts.calls == 1)
  await provider.release()
  #expect(try await first.value.credentialVersion == 2)
  #expect(try await queued.value.credentialVersion == 2)
  #expect(await provider.counts.peak == 1)
  service.stopAccepting()
  try await owner.value
  #expect(service.outstandingIdentities == 0 && service.waitingRequests == 0)
  let stoppedBeforeStart = try AccountRefreshSupervisor(
    application: fixture.app, provider: provider)
  stoppedBeforeStart.stopAccepting()
  await #expect(throws: AccountRefreshError.closed) { try await stoppedBeforeStart.run() }
  await fixture.close()
}

@Test(.timeLimit(.minutes(1)))
func refreshWorkerParallelismIsBoundedAndShutdownDoesNotStartQueuedTokens() async throws {
  let fixture = try await RefreshFixture.make(count: 6)
  let provider = RefreshProviderProbe()
  let service = try AccountRefreshSupervisor(
    application: fixture.app, provider: provider, parallelism: 2)
  let owner = Task { try await service.run() }
  defer { owner.cancel() }
  try await awaitRefreshCondition { service.isAccepting }
  let callers = fixture.accounts.map { account in
    Task { try await service.refreshAccount(id: account.id, revision: account.revision) }
  }
  try await awaitRefreshCondition {
    let counts = await provider.counts
    return service.outstandingIdentities == 6 && counts.active == 2
  }
  service.stopAccepting()
  for caller in callers { _ = await caller.result }
  try await owner.value
  let counts = await provider.counts
  #expect(counts.calls == 2 && counts.peak == 2 && counts.active == 0 && counts.cancellations == 2)
  let accounts = try await fixture.store.listAccounts()
  #expect(accounts.filter { $0.authorization == .authUncertain }.count == 2)
  #expect(accounts.filter { $0.authorization == .ready && $0.credentialVersion == 1 }.count == 4)
  #expect(service.outstandingIdentities == 0 && service.waitingRequests == 0)
  await fixture.close()
}

@Test(.timeLimit(.minutes(1)))
func refreshDeadlineAndParentCancellationPersistUncertaintyAndAwaitProvider() async throws {
  for parentCancellation in [false, true] {
    let fixture = try await RefreshFixture.make()
    let provider = RefreshProviderProbe()
    let service = try AccountRefreshSupervisor(
      application: fixture.app, provider: provider,
      timeoutMilliseconds: parentCancellation ? 10_000 : 50)
    let owner = Task { try await service.run() }
    defer { owner.cancel() }
    try await awaitRefreshCondition { service.isAccepting }
    let caller = Task { try await service.refreshAccount(id: "account-0", revision: 1) }
    try await awaitRefreshCondition { await provider.counts.active == 1 }
    if parentCancellation { owner.cancel() }
    let result = await caller.result
    #expect(result.isFailure)
    if !parentCancellation { service.stopAccepting() }
    _ = await owner.result
    let counts = await provider.counts
    #expect(counts.active == 0 && counts.cancellations == 1)
    #expect(
      try await fixture.store.accountCredential(id: "account-0").account.authorization
        == .authUncertain)
    #expect(service.outstandingIdentities == 0 && service.waitingRequests == 0)
    await fixture.close()
  }
}
extension Result {
  fileprivate var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}

private struct SyntheticProviderFailure: Error, CustomStringConvertible {
  var description: String { "synthetic-private-provider-detail" }
}
private struct FailureDuringRefresh: Service {
  let provider: RefreshProviderProbe
  func run() async throws {
    try await awaitRefreshCondition { await provider.counts.calls == 1 }
    throw SyntheticProviderFailure()
  }
}
@Test(.timeLimit(.minutes(1)))
func refreshOwnerSanitizesProviderErrorsAndParticipatesInRuntimeShutdown() async throws {
  for mode in ["provider-error", "runtime-stop", "identity-change"] {
    let runtimeFailure = mode == "runtime-stop"
    let fixture = try await RefreshFixture.make()
    let provider = RefreshProviderProbe(
      failAfterRelease: mode == "provider-error",
      namespaceOverride: mode == "identity-change" ? "synthetic/other" : nil)
    let service = try AccountRefreshSupervisor(application: fixture.app, provider: provider)
    let owner = Task {
      if runtimeFailure {
        try await GatewayRuntime(services: [service, FailureDuringRefresh(provider: provider)]).run(
          handleSignals: false)
      } else {
        try await service.run()
      }
    }
    defer { owner.cancel() }
    try await awaitRefreshCondition { service.isAccepting }
    let caller = Task { try await service.refreshAccount(id: "account-0", revision: 1) }
    if runtimeFailure {
      await #expect(throws: AccountRefreshError.closed) { try await caller.value }
      await #expect(throws: SyntheticProviderFailure.self) { try await owner.value }
    } else {
      try await awaitRefreshCondition { await provider.counts.active == 1 }
      await provider.release()
      let expected: AccountRefreshError = mode == "identity-change" ? .conflict : .unavailable
      await #expect(throws: expected) { try await caller.value }
      service.stopAccepting()
      try await owner.value
    }
    #expect(await provider.counts.active == 0)
    #expect(fixture.store.isAvailable)
    #expect(
      try await fixture.store.accountCredential(id: "account-0").account.authorization
        == .authUncertain)
    #expect(service.waitingRequests == 0 && service.outstandingIdentities == 0)
    await fixture.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func dispatchRefreshJoinsManagementGenerationAfterIntentWithoutReplayingOrphan() async throws {
  let f = try await RefreshFixture.make()
  let initial = f.accounts[0]
  let account = try await f.store.setAccountMode(
    id: initial.id, revision: initial.revision, mode: .enabled)
  let provider = RefreshProviderProbe()
  let service = try AccountRefreshSupervisor(application: f.app, provider: provider)
  let owner = Task { try await service.run() }
  defer { owner.cancel() }
  try await awaitRefreshCondition { service.isAccepting }
  let management = Task {
    try await service.refreshAccount(id: account.id, revision: account.revision)
  }
  try await awaitRefreshCondition { await provider.counts.calls == 1 }
  let pending = try await f.store.accountCredential(id: account.id).account
  #expect(
    pending.revision > account.revision && pending.credentialVersion == account.credentialVersion)
  let route = Task { try await service.refreshForDispatch(account: pending) }
  try await awaitRefreshCondition { service.waitingRequests == 2 }
  let cancelled = Task { try await service.refreshForDispatch(account: pending) }
  try await awaitRefreshCondition { service.waitingRequests == 3 }
  cancelled.cancel()
  await #expect(throws: AccountRefreshError.closed) { try await cancelled.value }
  let wrongGeneration = try ManagedAccount(
    id: pending.id, namespace: pending.namespace, revision: pending.revision,
    credentialVersion: pending.credentialVersion + 1, mode: pending.mode,
    authorization: pending.authorization, refreshIntent: pending.refreshIntent,
    createdAtUnixSeconds: pending.createdAtUnixSeconds)
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.refreshForDispatch(account: wrongGeneration)
  }
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.refreshAccount(id: pending.id, revision: pending.revision)
  }
  await provider.release()
  #expect(try await management.value.credentialVersion == 2)
  #expect(try await route.value.credentialVersion == 2)
  try await awaitRefreshCondition { service.outstandingIdentities == 0 }
  let current = try await f.store.accountCredential(id: account.id).account
  let orphan = try await f.app.beginRefresh(id: current.id, revision: current.revision)
  await #expect(throws: AccountRefreshError.conflict) {
    try await service.refreshForDispatch(account: orphan.account)
  }
  #expect(await provider.counts.calls == 1)
  service.stopAccepting()
  try await owner.value
  await f.close()
}
