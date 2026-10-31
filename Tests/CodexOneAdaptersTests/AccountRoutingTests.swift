import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private struct RoutingFixture {
  let path: String
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  let policy: AccountPoolPolicy
  static func make(limits: ExecutionLimits = syntheticLimits) async throws -> Self {
    let path = try temporaryExecutionPath()
    let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
    let app = AccountCredentials(
      store: store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "6b", count: 32)))
    for id in ["a", "b"] {
      let account = try await app.importVerified(
        id: id, namespace: "synthetic/\(id)",
        credential: AccountCredential(
          accessToken: "synthetic-access-\(id)", refreshToken: "synthetic-refresh-\(id)",
          idToken: nil, expiresAtUnixSeconds: 2_000_000_000))
      _ = try await store.setAccountMode(id: id, revision: account.revision, mode: .enabled)
    }
    let key = try await store.createKey(
      id: "key", principal: "p", digest: String(repeating: "a", count: 64),
      policy: KeyPolicy(models: ["synthetic-text"], limits: limits))
    let policy = try AccountPoolPolicy(
      key: key, models: ["synthetic-text"], reservedMicros: 1, policyVersion: "1",
      pricingVersion: "1")
    return Self(path: path, store: store, app: app, policy: policy)
  }
  func command(
    _ id: String, references: [ObjectBinding] = [], connection: AccountRouteIdentity? = nil,
    continuation: Bool = false
  ) async throws -> AccountPoolAdmission {
    var candidates: [AccountRouteCandidate] = []
    for id in ["a", "b"] {
      let work = try await app.prepareDispatch(id: id, continuation: continuation)
      candidates.append(try AccountRouteCandidate(work: work))
    }
    return try AccountPoolAdmission(
      attempt: id, policy: policy, model: "synthetic-text", window: "w", requestID: "stable-seed",
      mode: .generation, references: references, connection: connection, candidates: candidates)
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}
private let routeUsage = UsageEvidence(
  revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0, estimatedMicros: 1,
  completeness: .complete)
private func routeIdentity(_ command: ExecutionAdmission) throws -> AccountRouteIdentity {
  try .init(id: command.owner.identity, namespace: command.owner.namespace)
}

@Test func accountPoolSelectsLeastInflightAtomicallyAndTieSurvivesReopen() async throws {
  let f = try await RoutingFixture.make()
  let firstCommand = try await f.command("one")
  let secondCommand = try await f.command("two")
  async let first = f.store.admitSelectingAccount(firstCommand)
  async let second = f.store.admitSelectingAccount(secondCommand)
  let pair = try await [first, second]
  #expect(pair[0].owner.identity != pair[1].owner.identity)
  for admission in pair {
    try await f.store.finalize(attempt: admission.attempt, evidence: routeUsage)
  }
  let tie = try await f.store.admitSelectingAccount(f.command("tie"))
  try await f.store.finalize(attempt: tie.attempt, evidence: routeUsage)
  let repeatCommand = try await f.command("repeated")
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(path: f.path, limits: syntheticLimits)
  let repeated = try await reopened.admitSelectingAccount(repeatCommand)
  #expect(tie.owner == repeated.owner)
  await reopened.close()
  await f.close()
}

@Test func accountPoolAffinityIntersectsObjectsAndConnectionWithinPrincipal() async throws {
  let f = try await RoutingFixture.make()
  let one = try await f.store.admitSelectingAccount(f.command("one"))
  let two = try await f.store.admitSelectingAccount(f.command("two"))
  let shared = ObjectBinding(type: "response", rawID: "same-id")
  let unique = ObjectBinding(type: "response", rawID: "unique-id")
  for command in [one, two] { try await f.store.bind(attempt: command.attempt, object: shared) }
  try await f.store.bind(attempt: one.attempt, object: unique)
  await #expect(throws: ExecutionError.ambiguousObject) {
    try await f.store.resolveAccountAffinity(principal: "p", references: [shared], connection: nil)
  }
  let identity = try routeIdentity(one)
  #expect(
    try await f.store.resolveAccountAffinity(
      principal: "p", references: [shared, unique], connection: nil) == identity)
  #expect(
    try await f.store.resolveAccountAffinity(
      principal: "p", references: [shared], connection: identity) == identity)
  await #expect(throws: ExecutionError.unknownObject) {
    try await f.store.resolveAccountAffinity(
      principal: "other", references: [shared], connection: identity)
  }
  await #expect(throws: ExecutionError.unknownObject) {
    try await f.store.resolveAccountAffinity(
      principal: "p", references: [unique], connection: routeIdentity(two))
  }
  let admitted = try await f.store.admitSelectingAccount(
    f.command("intersection", references: [shared, unique], continuation: true))
  #expect(admitted.owner.identity == one.owner.identity)
  await f.close()
}

@Test func accountPoolRechecksBindingCollisionAndAccountChangesBeforeIntent() async throws {
  let f = try await RoutingFixture.make()
  let one = try await f.store.admitSelectingAccount(f.command("one"))
  let two = try await f.store.admitSelectingAccount(f.command("two"))
  let object = ObjectBinding(type: "response", rawID: "collision")
  try await f.store.bind(attempt: one.attempt, object: object)
  #expect(
    try await f.store.resolveAccountAffinity(principal: "p", references: [object], connection: nil)
      == routeIdentity(one))
  let prepared = try await f.command("collision", references: [object], continuation: true)
  try await f.store.bind(attempt: two.attempt, object: object)
  await #expect(throws: ExecutionError.ambiguousObject) {
    try await f.store.admitSelectingAccount(prepared)
  }
  let stale = try await f.command("stale")
  for account in try await f.store.listAccounts() {
    _ = try await f.store.setAccountMode(
      id: account.id, revision: account.revision, mode: .disabled)
  }
  await #expect(throws: AccountDispatchError.unavailable) {
    try await f.store.admitSelectingAccount(stale)
  }
  for attempt in ["collision", "stale"] {
    await #expect(throws: ExecutionError.unknownAttempt) {
      try await f.store.snapshot(attempt: attempt)
    }
  }
  await f.close()
}

@Test func accountPoolRequiresProvenContinuationForDrainingAndCurrentKey() async throws {
  let f = try await RoutingFixture.make()
  let first = try await f.store.admitSelectingAccount(f.command("first"))
  let object = ObjectBinding(type: "response", rawID: "existing")
  try await f.store.bind(attempt: first.attempt, object: object)
  for account in try await f.store.listAccounts() {
    _ = try await f.store.setAccountMode(
      id: account.id, revision: account.revision, mode: .draining)
  }
  let forged = try await f.command("forged", continuation: true)
  await #expect(throws: AccountDispatchError.unavailable) {
    try await f.store.admitSelectingAccount(forged)
  }
  let valid = try await f.store.admitSelectingAccount(
    f.command("continuation", references: [object], continuation: true))
  #expect(valid.owner.identity == first.owner.identity)
  let revoked = try await f.command("revoked", references: [object], continuation: true)
  _ = try await f.store.updateKey(
    id: f.policy.key.id, revision: f.policy.key.revision, enabled: false,
    policy: f.policy.key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await f.store.admitSelectingAccount(revoked)
  }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await f.store.snapshot(attempt: "revoked")
  }
  await f.close()
}

@Test func accountPoolGlobalLimitRejectsWithoutTryingAnotherAccount() async throws {
  let f = try await RoutingFixture.make(
    limits: .init(requests: 100, active: 1, unresolved: 4, budgetMicros: 100))
  _ = try await f.store.admitSelectingAccount(f.command("first"))
  await #expect(throws: ExecutionError.denied) {
    try await f.store.admitSelectingAccount(f.command("second"))
  }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await f.store.snapshot(attempt: "second")
  }
  await f.close()
}

@Test func accountHealthAtomicallyFiltersNewRequestsAndPinnedConnectionsUntilCredentialChanges()
  async throws
{
  let f = try await RoutingFixture.make()
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("health-auth"))
  let outcome = try ExecutionOutcome(
    failure: .authenticationRejected, atUnixSeconds: Int64(Date().timeIntervalSince1970))
  try await f.store.finalize(attempt: first.attempt, evidence: nil, outcome: outcome)
  #expect(try await f.store.accountHealth(id: first.owner.identity).authenticationRejected)
  let other = try await f.store.admitSelectingAccount(f.command("health-other"))
  #expect(other.owner.identity != first.owner.identity)
  try await f.store.finalize(attempt: other.attempt, evidence: routeUsage)
  await #expect(throws: AccountDispatchError.unavailable) {
    try await f.store.admitSelectingAccount(
      f.command("health-pinned", connection: routeIdentity(first), continuation: true))
  }
  let work = try await f.app.prepareDispatch(id: first.owner.identity, continuation: true)
  _ = try await f.app.reauthorizeVerified(
    id: work.account.id, revision: work.account.revision,
    namespace: work.account.namespace, credential: work.credential)
  #expect(try await !f.store.accountHealth(id: first.owner.identity).authenticationRejected)
  let resumed = try await f.store.admitSelectingAccount(
    f.command("health-resumed", connection: routeIdentity(first), continuation: true))
  #expect(resumed.owner.identity == first.owner.identity)
  try await f.store.finalize(attempt: resumed.attempt, evidence: routeUsage)
  // A late duplicate from the old credential cannot re-block the new generation.
  try await f.store.finalize(attempt: first.attempt, evidence: nil, outcome: outcome)
  #expect(try await !f.store.accountHealth(id: first.owner.identity).authenticationRejected)
  await f.close()
}

@Test func accountModelCooldownIsDurableIdempotentAndIndependentOfLocalFailures() async throws {
  let f = try await RoutingFixture.make()
  try await f.store.configureHealthModels(["synthetic-text"])
  let failed = try await f.store.admitSelectingAccount(f.command("health-limited"))
  let outcome = try ExecutionOutcome(
    failure: .rateLimited, atUnixSeconds: Int64(Date().timeIntervalSince1970), cooldownSeconds: 60)
  try await f.store.finalize(attempt: failed.attempt, evidence: nil, outcome: outcome)
  let health = try await f.store.accountHealth(id: failed.owner.identity)
  #expect(health.cooldowns.count == 1 && !health.authenticationRejected)
  try await f.store.finalize(attempt: failed.attempt, evidence: nil, outcome: outcome)
  #expect(try await f.store.accountHealth(id: failed.owner.identity) == health)
  await #expect(throws: ExecutionError.conflict) {
    try await f.store.finalize(
      attempt: failed.attempt, evidence: nil,
      outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: outcome.atUnixSeconds))
  }
  let candidate = try await f.command("health-healthy")
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(path: f.path, limits: syntheticLimits)
  let healthy = try await reopened.admitSelectingAccount(candidate)
  #expect(healthy.owner.identity != failed.owner.identity)
  #expect(try await reopened.accountHealth(id: failed.owner.identity) == health)
  try await reopened.finalize(
    attempt: healthy.attempt, evidence: routeUsage,
    outcome: .init(failure: .clientCancelled, atUnixSeconds: outcome.atUnixSeconds))
  let local = try await reopened.accountHealth(id: healthy.owner.identity)
  #expect(local.lastFailure == nil && local.cooldowns.isEmpty && !local.authenticationRejected)
  // Removing a no-longer-supported scope cannot consume new scope capacity.
  try await reopened.configureHealthModels(["another-synthetic-model"])
  #expect(try await reopened.accountHealth(id: failed.owner.identity).cooldowns.isEmpty)
  await reopened.close()
  await f.close()
}

@Test func quotaFailurePreservesSuccessAndOldCredentialCannotOverwriteObservation() async throws {
  let f = try await RoutingFixture.make()
  let account = try await f.store.accountCredential(id: "a").account
  let quota = try SubscriptionQuota(limits: [
    .init(
      id: "codex", allowed: true, limitReached: false,
      primary: .init(usedPercent: 12.5, durationSeconds: 18000, resetsAtUnixSeconds: 2_000_000_000),
      secondary: nil)
  ])
  let first = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: 1000, result: .success(quota))
  #expect(first.isFresh(at: 1299) && !first.isFresh(at: 1300) && !first.isFresh(at: 999))
  let failed = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: 1301, result: .failure(.unavailable))
  #expect(
    failed.quota == quota && failed.observedAtUnixSeconds == 1000
      && failed.attemptedAtUnixSeconds == 1301)
  let work = try await f.app.prepareDispatch(id: "a", continuation: false)
  _ = try await f.app.reauthorizeVerified(
    id: "a", revision: work.account.revision,
    namespace: work.account.namespace, credential: work.credential)
  await #expect(throws: ExecutionError.conflict) {
    try await f.store.recordQuotaObservation(
      account: account, atUnixSeconds: 1400, result: .success(quota))
  }
  #expect(try await f.store.quotaObservation(id: "a") == failed)
  await f.close()
}

@Test func accountPoolIdentityCapacityDoesNotReusePrincipalLimit() async throws {
  let f = try await RoutingFixture.make(
    limits: .init(requests: 100, active: 10, unresolved: 2, budgetMicros: 100))
  for index in 0..<3 {
    let key = try await f.store.createKey(
      id: "key-\(index)", principal: "p-\(index)",
      digest: String(repeating: String(index + 1), count: 64),
      policy: KeyPolicy(models: ["synthetic-text"], limits: syntheticLimits))
    let policy = try AccountPoolPolicy(
      key: key, models: ["synthetic-text"], reservedMicros: 1,
      policyVersion: "1", pricingVersion: "1")
    let work = try await f.app.prepareDispatch(id: "a", continuation: false)
    let command = try AccountPoolAdmission(
      attempt: "capacity-\(index)", policy: policy,
      model: "synthetic-text", window: "w", requestID: "seed", mode: .generation,
      references: [], connection: nil, candidates: [AccountRouteCandidate(work: work)])
    let admitted = try await f.store.admitSelectingAccount(command)
    #expect(admitted.owner.identity == "a")
    try await f.store.finalize(attempt: admitted.attempt, evidence: nil)
  }
  await f.close()
}
