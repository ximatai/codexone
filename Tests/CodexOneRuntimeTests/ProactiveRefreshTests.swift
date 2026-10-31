import CodexOneCore
import CodexOneRuntime
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private actor ProactiveProvider: AccountRefreshProvider, AccountQuotaProvider {
  var refreshes = 0
  var observations = 0
  var failure: AccountRefreshError?
  var gate: AsyncStream<Void>?
  init(failure: AccountRefreshError? = nil, gate: AsyncStream<Void>? = nil) {
    self.failure = failure
    self.gate = gate
  }
  func refresh(credential: AccountCredential, namespace: String) async throws
    -> VerifiedAccountRefresh
  {
    refreshes += 1
    if let gate { for await _ in gate { break } }
    if let failure {
      self.failure = nil
      throw failure
    }
    return try .init(
      namespace: namespace,
      credential: .init(
        accessToken: "synthetic-proactive-access", refreshToken: "synthetic-proactive-refresh",
        idToken: nil, expiresAtUnixSeconds: 2_000_010_000))
  }
  func observe(_ work: AccountObservationWork) async throws -> SubscriptionQuota {
    observations += 1
    return try SubscriptionQuota(limits: [])
  }
}
private func spinUntil(_ condition: @Sendable () async throws -> Bool) async throws {
  for _ in 0..<100_000 {
    if try await condition() { return }
    await Task.yield()
  }
  throw AccountRefreshError.unavailable
}

@Test(.timeLimit(.minutes(1)))
func proactiveRefreshWindowCyclesAndConcurrentWaitersShareOneRotation() async throws {
  let f = try await RefreshFixture.make()
  let clock = Mutex<Int64>(2_000_000_000 - 901)
  let app = AccountCredentials(
    store: f.store,
    protection: try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32)),
    now: { clock.withLock { $0 } })
  var account = try await f.store.setAccountMode(
    id: f.accounts[0].id,
    revision: f.accounts[0].revision, mode: .enabled)
  let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let provider = ProactiveProvider(gate: gate.stream)
  let refresh = try AccountRefreshSupervisor(application: app, provider: provider)
  let observer = try AccountObservationSupervisor(
    store: f.store, application: app,
    refresher: refresh, provider: provider, intervalMilliseconds: 300_000)
  let refreshOwner = Task { try await refresh.run() }
  try await spinUntil { refresh.isAccepting }
  let observationOwner = Task { try await observer.run() }
  try await spinUntil { observer.isAccepting }
  _ = try await observer.observeAccount(id: account.id)
  #expect(await provider.refreshes == 0)
  clock.withLock { $0 += 1 }
  try await observer.scheduleCycle()
  try await spinUntil { await provider.refreshes == 1 }
  let captured = account
  let waiter = Task { try await refresh.refreshForDispatch(account: captured) }
  try await spinUntil { refresh.waitingRequests == 2 }
  for _ in 0..<3 { try await observer.scheduleCycle() }
  gate.continuation.yield(())
  gate.continuation.finish()
  account = try await waiter.value
  try await spinUntil { observer.outstandingAccounts == 0 }
  #expect(account.credentialVersion == captured.credentialVersion + 1)
  for _ in 0..<3 {
    try await observer.scheduleCycle()
    _ = try await observer.observeAccount(id: account.id)
  }
  #expect(await provider.refreshes == 1)
  observer.stopAccepting()
  refresh.stopAccepting()
  _ = await observationOwner.result
  _ = await refreshOwner.result
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func proactiveRefreshFailureClassificationAndRetryPreserveCredentialSafety() async throws {
  for failure: AccountRefreshError in [.notCompleted, .authorizationRequired, .unavailable] {
    let f = try await RefreshFixture.make()
    let app = AccountCredentials(
      store: f.store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32)),
      now: { 2_000_000_000 - 900 })
    let account = try await f.store.setAccountMode(
      id: f.accounts[0].id,
      revision: f.accounts[0].revision, mode: .draining)
    let provider = ProactiveProvider(failure: failure)
    let refresh = try AccountRefreshSupervisor(application: app, provider: provider)
    let observer = try AccountObservationSupervisor(
      store: f.store, application: app,
      refresher: refresh, provider: provider, intervalMilliseconds: 300_000)
    let refreshOwner = Task { try await refresh.run() }
    try await spinUntil { refresh.isAccepting }
    let observationOwner = Task { try await observer.run() }
    try await spinUntil { await provider.refreshes == 1 && observer.outstandingAccounts == 0 }
    let stored = try await f.store.accountCredential(id: account.id).account
    #expect(
      stored.authorization
        == (failure == .notCompleted
          ? .ready : failure == .authorizationRequired ? .requiresAuth : .authUncertain))
    #expect(stored.credentialVersion == account.credentialVersion)
    if failure == .notCompleted {
      #expect(
        try await app.prepareDispatch(id: account.id, continuation: true).account.authorization
          == .ready)
      try await observer.scheduleCycle()
      try await spinUntil { await provider.refreshes == 2 && observer.outstandingAccounts == 0 }
      #expect(
        try await f.store.accountCredential(id: account.id).account.credentialVersion == stored
          .credentialVersion + 1)
    } else {
      try await observer.scheduleCycle()
      #expect(await provider.refreshes == 1)
    }
    observer.stopAccepting()
    refresh.stopAccepting()
    _ = await observationOwner.result
    _ = await refreshOwner.result
    await f.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func proactiveRefreshNeverRefreshesDisabledAccountsEvenOnManualObservation() async throws {
  let f = try await RefreshFixture.make()
  let app = AccountCredentials(
    store: f.store,
    protection: try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32)),
    now: { 2_000_000_000 - 300 })
  let provider = ProactiveProvider()
  let refresh = try AccountRefreshSupervisor(application: app, provider: provider)
  let observer = try AccountObservationSupervisor(
    store: f.store, application: app,
    refresher: refresh, provider: provider)
  let owner = Task { try await observer.run() }
  try await spinUntil { observer.isAccepting }
  try await observer.scheduleCycle()
  _ = try await observer.observeAccount(id: f.accounts[0].id)
  #expect(await provider.observations == 1)
  #expect(await provider.refreshes == 0)
  observer.stopAccepting()
  _ = await owner.result
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func proactiveRefreshAlsoRecoversReadyExpiredCredentials() async throws {
  let f = try await RefreshFixture.make()
  let app = AccountCredentials(
    store: f.store,
    protection: try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32)),
    now: { 2_000_000_001 })
  let account = try await f.store.setAccountMode(
    id: f.accounts[0].id,
    revision: f.accounts[0].revision, mode: .enabled)
  let provider = ProactiveProvider()
  let refresh = try AccountRefreshSupervisor(application: app, provider: provider)
  let observer = try AccountObservationSupervisor(
    store: f.store, application: app,
    refresher: refresh, provider: provider)
  let refreshOwner = Task { try await refresh.run() }
  try await spinUntil { refresh.isAccepting }
  let observerOwner = Task { try await observer.run() }
  try await spinUntil { await provider.refreshes == 1 && observer.outstandingAccounts == 0 }
  #expect(try await f.store.accountCredential(id: account.id).account.credentialVersion == 2)
  #expect(await provider.observations == 1)
  observer.stopAccepting()
  refresh.stopAccepting()
  _ = await observerOwner.result
  _ = await refreshOwner.result
  await f.close()
}
