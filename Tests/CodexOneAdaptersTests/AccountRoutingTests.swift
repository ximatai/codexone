import CodexOneCore
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private struct RoutingFixture {
  let ids: [String]
  let path: String
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  let policy: AccountPoolPolicy
  static func make(
    limits: ExecutionLimits = syntheticLimits, clock: WallClock = testClock,
    ids: [String] = ["a", "b"],
    pacingSleep: @escaping @Sendable (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  )
    async throws -> Self
  {
    let path = try temporaryExecutionPath()
    let store = try await SQLiteExecutionStore.open(
      path: path, limits: limits, clock: clock, pacingSleep: pacingSleep)
    let app = AccountCredentials(
      store: store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "6b", count: 32)),
      clock: clock)
    for id in ids {
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
    return Self(ids: ids, path: path, store: store, app: app, policy: policy)
  }
  func command(
    _ id: String, references: [ObjectBinding] = [], connection: AccountRouteIdentity? = nil,
    continuation: Bool = false, preferred: AccountRouteIdentity? = nil
  ) async throws -> AccountPoolAdmission {
    var candidates: [AccountRouteCandidate] = []
    for id in ids {
      let work = try await app.prepareDispatch(id: id, continuation: continuation)
      candidates.append(try AccountRouteCandidate(work: work))
    }
    return try AccountPoolAdmission(
      attempt: id, policy: policy, model: "synthetic-text", window: "w", requestID: "stable-seed",
      mode: .generation, references: references, connection: connection, candidates: candidates,
      preferred: preferred)
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
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: testClock)
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
    failure: .authenticationRejected, atUnixSeconds: testUnixSeconds)
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
    failure: .rateLimited, atUnixSeconds: testUnixSeconds, cooldownSeconds: 60)
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
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: testClock)
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
  let quota = try SubscriptionQuota(
    limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: .init(
          usedPercent: 12.5, durationSeconds: 18000, resetsAtUnixSeconds: 2_000_000_000),
        secondary: nil)
    ], usageCredits: .balance("12345.67"))
  let first = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: 1000, result: .success(quota))
  #expect(first.isFresh(at: 1299) && !first.isFresh(at: 1300) && !first.isFresh(at: 999))
  let failed = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: 1301, result: .failure(.unavailable))
  #expect(
    failed.quota == quota && failed.observedAtUnixSeconds == 1000
      && failed.attemptedAtUnixSeconds == 1301)
  let health = try await f.store.accountHealth(id: account.id)
  let summary = accountObservationDTO(
    failed, health: health, observing: true, detail: false, now: 1301)
  let detail = accountObservationDTO(
    failed, health: health, observing: true, detail: true, now: 1301)
  #expect(summary["quota"]?["usageCredits"] == nil)
  #expect(detail["quota"]?["usageCredits"]?["balance"] == .string("12345.67"))
  let other = try await f.store.quotaObservation(id: "b")
  #expect(other.quota?.usageCredits == nil)
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

@Test func accountCooldownRejectsPinnedDispatchUntilExactEndAcrossRestart() async throws {
  let time = TestWallClock()
  let f = try await RoutingFixture.make(clock: time.clock)
  try await f.store.configureHealthModels(["synthetic-text"])
  let failed = try await f.store.admitSelectingAccount(f.command("cooldown-start"))
  let identity = try routeIdentity(failed)
  try await f.store.finalize(
    attempt: failed.attempt, evidence: nil,
    outcome: .init(
      failure: .rateLimited, atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 60))
  time.advance(seconds: 59)
  let blocked = try await f.command("cooldown-blocked", connection: identity, continuation: true)
  await #expect(throws: AccountDispatchError.unavailable) {
    try await f.store.admitSelectingAccount(blocked)
  }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await f.store.snapshot(attempt: "cooldown-blocked")
  }
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: time.clock)
  #expect(try await reopened.accountHealth(id: identity.id).cooldowns.count == 1)
  time.advance(seconds: 1)
  #expect(try await reopened.accountHealth(id: identity.id).cooldowns.isEmpty)
  // The prepared snapshot is still current: the durable cooldown alone blocked admission.
  let admitted = try await reopened.admitSelectingAccount(blocked)
  #expect(admitted.owner.identity == identity.id)
  try await reopened.finalize(attempt: admitted.attempt, evidence: routeUsage)
  await reopened.close()
  await f.close()
}

@Test func overloadPacingPersistsEveryStepAndSuccessResetsWithoutElapsedTimeReset() async throws {
  let time = TestWallClock()
  let limits = ExecutionLimits(requests: 100, active: 32, unresolved: 100, budgetMicros: 1000)
  let f = try await RoutingFixture.make(limits: limits, clock: time.clock, ids: ["a"])
  try await f.store.configureHealthModels(["synthetic-text"])
  for (index, step) in [1, 2, 4, 8, 15, 15].enumerated() {
    let admitted = try await f.store.admitSelectingAccount(f.command("overload-\(index)"))
    let outcome = try ExecutionOutcome(
      failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds)
    try await f.store.finalize(attempt: admitted.attempt, evidence: nil, outcome: outcome)
    // Repeated finalization neither escalates nor extends the step.
    try await f.store.finalize(attempt: admitted.attempt, evidence: nil, outcome: outcome)
    let health = try await f.store.accountHealth(id: "a")
    #expect(health.cooldowns.first?.untilUnixSeconds == time.clock.unixSeconds + Int64(step))
    #expect(try await f.app.hasLocallyRoutableAccount(models: ["synthetic-text"]) == (step <= 15))
    do {
      _ = try await f.store.admitSelectingAccount(f.command("blocked-\(index)"))
      Issue.record("Live overload admitted before its deadline")
    } catch let wait as AccountPacingRequired {
      #expect(step <= 15 && wait.seconds == Double(step))
    } catch let unavailable as AccountCooldownUnavailable {
      #expect(step > 15 && unavailable.retryAfter == Int64(step))
      #expect(protocolFailure(unavailable).status == 503)
      #expect(protocolFailure(unavailable).cooldownSeconds == Int64(step))
    }
    await #expect(throws: ExecutionError.unknownAttempt) {
      try await f.store.snapshot(attempt: "blocked-\(index)")
    }
    time.advance(seconds: Int64(step))
    #expect(try await f.app.hasLocallyRoutableAccount(models: ["synthetic-text"]))
  }
  let success = try await f.store.admitSelectingAccount(f.command("reset-success"))
  try await f.store.finalize(
    attempt: success.attempt, evidence: routeUsage,
    outcome: .init(failure: nil, atUnixSeconds: time.clock.unixSeconds))
  let next = try await f.store.admitSelectingAccount(f.command("reset-overload"))
  try await f.store.finalize(
    attempt: next.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  #expect(
    try await f.store.accountHealth(id: "a").cooldowns.first?.untilUnixSeconds == time.clock
      .unixSeconds + 1)
  let prepared = try await f.command("restart-overload")
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: limits, clock: time.clock)
  await #expect(throws: AccountPacingRequired.self) {
    try await reopened.admitSelectingAccount(prepared)
  }
  time.advance(seconds: 1)
  let afterRestart = try await reopened.admitSelectingAccount(prepared)
  try await reopened.finalize(
    attempt: afterRestart.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  #expect(
    try await reopened.accountHealth(id: "a").cooldowns.first?.untilUnixSeconds == time.clock
      .unixSeconds + 1)
  await reopened.close()
  await f.close()
}

@Test func overloadPoolAvoidsPacingAndWaitsEarliestWhilePinnedNeverSwitches() async throws {
  let time = TestWallClock()
  let f = try await RoutingFixture.make(clock: time.clock)
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("paced-first"))
  try await f.store.finalize(
    attempt: first.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  await #expect(throws: AccountPacingRequired.self) {
    try await f.store.admitSelectingAccount(
      f.command("paced-pinned", connection: routeIdentity(first), continuation: true))
  }
  let second = try await f.store.admitSelectingAccount(
    f.command("paced-other"))
  #expect(second.owner.identity != first.owner.identity)
  try await f.store.finalize(
    attempt: second.attempt, evidence: nil,
    outcome: .init(
      failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 2))
  do {
    _ = try await f.store.admitSelectingAccount(f.command("all-paced"))
    Issue.record("Expected earliest pacing wait")
  } catch let wait as AccountPacingRequired { #expect(wait.seconds == 1) }
  time.advance(seconds: 1)
  let selected = try await f.store.admitSelectingAccount(f.command("paced-expired"))
  #expect(selected.owner.identity == first.owner.identity)
  try await f.store.finalize(
    attempt: selected.attempt, evidence: nil,
    outcome: .init(failure: .rateLimited, atUnixSeconds: time.clock.unixSeconds))
  time.advance(seconds: 1)
  let avoids429 = try await f.store.admitSelectingAccount(f.command("avoids-429"))
  #expect(avoids429.owner.identity == second.owner.identity)
  await f.close()
}

@Test func overloadPacingKeepsFullSubsecondStepAndHonorsTrustedRetryAfter() async throws {
  let time = TestWallClock()
  let fractional = WallClock { Double(time.clock.unixSeconds) + 0.9 }
  let f = try await RoutingFixture.make(clock: fractional, ids: ["a"])
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("fractional"))
  try await f.store.finalize(
    attempt: first.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  do {
    _ = try await f.store.admitSelectingAccount(f.command("fractional-wait"))
    Issue.record("Expected a full one second wait")
  } catch let wait as AccountPacingRequired { #expect(abs(wait.seconds - 1) < 0.00001) }
  time.advance(seconds: 1)
  let next = try await f.store.admitSelectingAccount(f.command("trusted-retry"))
  try await f.store.finalize(
    attempt: next.attempt, evidence: nil,
    outcome: .init(
      failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 20))
  do {
    _ = try await f.store.admitSelectingAccount(f.command("trusted-blocked"))
    Issue.record("Expected trusted Retry-After")
  } catch let unavailable as AccountCooldownUnavailable {
    #expect(unavailable.retryAfter == 20)
    #expect(protocolFailure(unavailable).status == 503)
    #expect(protocolFailure(unavailable).cooldownSeconds == 20)
  }
  #expect(try await !f.app.hasLocallyRoutableAccount(models: ["synthetic-text"]))
  time.advance(seconds: 20)
  let last = try await f.store.admitSelectingAccount(f.command("after-trusted"))
  try await f.store.finalize(
    attempt: last.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  #expect(
    try await f.store.accountHealth(id: "a").cooldowns.first?.untilUnixSeconds == time.clock
      .unixSeconds + 3)
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func overloadReleasedWaitersRecheckAccountConcurrencyAndKeyLimits() async throws {
  let time = TestWallClock()
  let waiting = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let limits = ExecutionLimits(requests: 100, active: 32, unresolved: 32, budgetMicros: 1000)
  let f = try await RoutingFixture.make(limits: limits, clock: time.clock, ids: ["a"]) { _ in
    waiting.continuation.yield(())
    for await _ in release.stream { break }
    try Task.checkCancellation()
  }
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("release-overload"))
  try await f.store.finalize(
    attempt: first.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  var commands: [AccountPoolAdmission] = []
  for index in 0..<ExecutionLimits.accountConcurrency {
    commands.append(try await f.command("released-\(index)"))
  }
  let tasks = commands.map { command in
    Task {
      await #expect(throws: AccountPacingRequired.self) {
        try await f.store.admitSelectingAccount(command)
      }
      try await f.store.waitForAccountPacing(seconds: 1)
      return try await f.store.admitSelectingAccount(command)
    }
  }
  var arrivals = waiting.stream.makeAsyncIterator()
  for _ in tasks { _ = await arrivals.next() }
  #expect(
    try await f.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='intent'")
    } == 0)
  time.advance(seconds: 1)
  release.continuation.finish()
  for task in tasks { _ = try await task.value }
  #expect(
    try await f.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='intent'")
    } == ExecutionLimits.accountConcurrency)
  await #expect(throws: ExecutionError.accountConcurrency) {
    try await f.store.admitSelectingAccount(f.command("released-over-capacity"))
  }
  for command in commands {
    try await f.store.finalize(attempt: command.attempt, evidence: routeUsage)
  }
  _ = try await f.store.updateKey(
    id: f.policy.key.id, revision: f.policy.key.revision, enabled: false,
    policy: f.policy.key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await f.store.admitSelectingAccount(f.command("released-revoked"))
  }
  await f.close()
}

@Test func overloadConcurrentCompletionCannotShortenTrustedDeadlineAcrossRestart() async throws {
  for restart in [false, true] {
    let time = TestWallClock()
    let fractional = WallClock { Double(time.clock.unixSeconds) + 0.1 }
    let f = try await RoutingFixture.make(clock: fractional, ids: ["a"])
    try await f.store.configureHealthModels(["synthetic-text"])
    let first = try await f.store.admitSelectingAccount(f.command("overlap-trusted"))
    let second = try await f.store.admitSelectingAccount(f.command("overlap-default"))
    try await f.store.finalize(
      attempt: first.attempt, evidence: nil,
      outcome: .init(
        failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 2))
    let check = try await f.command("overlap-check")
    let store: SQLiteExecutionStore
    if restart {
      await f.store.close()
      store = try await SQLiteExecutionStore.open(
        path: f.path, limits: syntheticLimits, clock: fractional)
    } else {
      store = f.store
    }
    try await store.finalize(
      attempt: second.attempt, evidence: nil,
      outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
    do {
      _ = try await store.admitSelectingAccount(check)
      Issue.record("Expected trusted deadline to survive overlapping default pacing")
    } catch let wait as AccountPacingRequired {
      #expect(abs(wait.seconds - 1.9) < 0.00001)
    }
    await store.close()
    await f.close()
  }
}

private final class RoutingFinalizer: FinalizationSink, Sendable {
  let results = Mutex<[Finalization]>([])
  var isAccepting: Bool { true }
  func reserve() throws -> UUID { UUID() }
  func canExecute(_ ticket: UUID) -> Bool { true }
  func abandon(_ ticket: UUID) {}
  func handoff(_ ticket: UUID, finalization: Finalization) {
    results.withLock { $0.append(finalization) }
  }
}

@Test(.timeLimit(.minutes(1)))
func overloadSoftPreferredWaitsThenGatewayReselectsPreferred() async throws {
  let time = TestWallClock()
  let waits = AsyncStream<Double>.makeStream()
  let f = try await RoutingFixture.make(clock: time.clock) { seconds in
    waits.continuation.yield(seconds)
    time.advance(seconds: Int64(seconds))
  }
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("preferred-start"))
  let hint = ObjectBinding(type: "response", rawID: "synthetic-soft-history")
  try await f.store.bind(attempt: first.attempt, object: hint)
  try await f.store.finalize(
    attempt: first.attempt, evidence: nil,
    outcome: .init(
      failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 2))
  let preferred = try routeIdentity(first)
  do {
    _ = try await f.store.admitSelectingAccount(f.command("preferred-wait", preferred: preferred))
    Issue.record("Expected soft preference pacing wait")
  } catch let wait as AccountPacingRequired { #expect(wait.seconds == 2) }
  #expect(
    try await f.store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='intent'")
    } == 0)
  let finalizer = RoutingFinalizer()
  let gateway = AccountPoolGateway(
    policy: f.policy, store: f.store, credentials: f.app, finalizer: finalizer, clock: time.clock)
  try await gateway.execute(model: "synthetic-text", references: [], affinityHints: [hint]) {
    context, work in
    #expect(context.admission.owner.identity == preferred.id)
    #expect(work.account.id == preferred.id)
    return routeUsage
  }
  waits.continuation.finish()
  var observed: [Double] = []
  for await seconds in waits.stream { observed.append(seconds) }
  #expect(observed == [2])
  #expect(finalizer.results.withLock { $0.count } == 1)
  await f.close()
}

@Test(arguments: ["long-overload", "429", "capacity", "paced-capacity"])
func overloadSoftPreferredFallsBackWhenNotOnlyShortPacing(blocker: String) async throws {
  let time = TestWallClock()
  let limits = ExecutionLimits(requests: 100, active: 32, unresolved: 100, budgetMicros: 1000)
  let f = try await RoutingFixture.make(limits: limits, clock: time.clock)
  try await f.store.configureHealthModels(["synthetic-text"])
  let preferred = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  let first = try await f.store.admitSelectingAccount(
    f.command("fallback-start", preferred: preferred))
  if blocker.contains("capacity") {
    for index in 1..<ExecutionLimits.accountConcurrency {
      _ = try await f.store.admitSelectingAccount(
        f.command("held-\(index)", preferred: preferred))
    }
    if blocker == "paced-capacity" {
      let work = try await f.app.prepareDispatch(id: preferred.id, continuation: false)
      try await f.store.recordAccountWideOutcome(
        account: AccountRouteCandidate(work: work),
        outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
    }
  } else {
    try await f.store.finalize(
      attempt: first.attempt, evidence: nil,
      outcome: .init(
        failure: blocker == "429" ? .rateLimited : .upstreamUnavailable,
        atUnixSeconds: time.clock.unixSeconds, cooldownSeconds: 4))
  }
  let selected = try await f.store.admitSelectingAccount(
    f.command("fallback", preferred: preferred))
  #expect(selected.owner.identity == "b")
  await f.close()
}

@Test func overloadSoftPreferredChecksKeyBeforeWaiting() async throws {
  let time = TestWallClock()
  let f = try await RoutingFixture.make(clock: time.clock)
  try await f.store.configureHealthModels(["synthetic-text"])
  let first = try await f.store.admitSelectingAccount(f.command("key-start"))
  try await f.store.finalize(
    attempt: first.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  _ = try await f.store.updateKey(
    id: f.policy.key.id, revision: f.policy.key.revision, enabled: false,
    policy: f.policy.key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await f.store.admitSelectingAccount(
      f.command("key-revoked", preferred: routeIdentity(first)))
  }
  await f.close()
}

@Test(arguments: [false, true])
func overloadSingleAccountEightSecondWaitForwardsOrEndsAtDeadline(shortDeadline: Bool) async throws
{
  let time = TestWallClock()
  let waits = Mutex<[Double]>([])
  let limits = ExecutionLimits(requests: 100, active: 32, unresolved: 100, budgetMicros: 1000)
  let f = try await RoutingFixture.make(limits: limits, clock: time.clock, ids: ["a"]) { seconds in
    waits.withLock { $0.append(seconds) }
    if shortDeadline {
      try await Task.sleep(for: .seconds(seconds))
    } else {
      time.advance(seconds: Int64(seconds))
    }
  }
  try await f.store.configureHealthModels(["synthetic-text"])
  for (index, step) in [1, 2, 4, 8].enumerated() {
    let admission = try await f.store.admitSelectingAccount(f.command("step-\(index)"))
    try await f.store.finalize(
      attempt: admission.attempt, evidence: nil,
      outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
    if step < 8 { time.advance(seconds: Int64(step)) }
  }
  #expect(try await f.app.hasLocallyRoutableAccount(models: ["synthetic-text"]))
  let healthBefore = try await f.store.accountHealth(id: "a")
  let finalizer = RoutingFinalizer()
  let gateway = AccountPoolGateway(
    policy: f.policy, store: f.store, credentials: f.app, finalizer: finalizer, clock: time.clock)
  let forwarded = Mutex(false)
  do {
    try await withExecutionDeadline(seconds: shortDeadline ? 1 : 60) {
      try await gateway.execute(model: "synthetic-text", references: []) { _, _ in
        forwarded.withLock { $0 = true }
        return routeUsage
      }
    }
    #expect(!shortDeadline)
  } catch {
    #expect(shortDeadline)
    #expect(protocolFailure(error).status == 504)
  }
  #expect(waits.withLock { $0 } == [8])
  #expect(forwarded.withLock { $0 } == !shortDeadline)
  if shortDeadline {
    #expect(try await f.store.accountHealth(id: "a").cooldowns == healthBefore.cooldowns)
    #expect(finalizer.results.withLock { $0.isEmpty })
    #expect(
      try await f.store.perform {
        try $0.scalar("SELECT COUNT(*) FROM attempts WHERE state='intent'")
      } == 0)
  }
  await f.close()
}

@Test(arguments: [false, true])
func overloadFullCoolingAccountDoesNotBecomeAWaitCandidate(hasAlternative: Bool) async throws {
  let time = TestWallClock()
  let f = try await RoutingFixture.make(
    limits: .init(requests: 100, active: 32, unresolved: 32, budgetMicros: 1000),
    clock: time.clock, ids: hasAlternative ? ["a", "b"] : ["a"])
  try await f.store.configureHealthModels(["synthetic-text"])
  let preferred = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  for index in 0..<ExecutionLimits.accountConcurrency {
    _ = try await f.store.admitSelectingAccount(f.command("full-\(index)", preferred: preferred))
  }
  for id in f.ids {
    let work = try await f.app.prepareDispatch(id: id, continuation: false)
    try await f.store.recordAccountWideOutcome(
      account: AccountRouteCandidate(work: work),
      outcome: .init(
        failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds,
        cooldownSeconds: id == "a" ? 2 : 20))
  }
  if hasAlternative {
    do {
      _ = try await f.store.admitSelectingAccount(f.command("must-not-wait-on-full"))
      Issue.record("Expected the available-capacity account's longer Retry-After")
    } catch let unavailable as AccountCooldownUnavailable {
      #expect(unavailable.retryAfter == 20)
    }
  } else {
    await #expect(throws: ExecutionError.accountConcurrency) {
      try await f.store.admitSelectingAccount(f.command("must-not-wait-on-full"))
    }
  }
  #expect(try await f.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") } == 16)
  await f.close()
}

@Test(.timeLimit(.minutes(1)))
func overloadWaitRechecksObservedTokenLimitBeforeIntent() async throws {
  let time = TestWallClock()
  let waiting = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let f = try await RoutingFixture.make(
    limits: .init(
      requests: 100, active: 4, unresolved: 4, budgetMicros: 100,
      unresolvedMicros: 100, tokens: 2), clock: time.clock, ids: ["a"]
  ) { _ in
    waiting.continuation.yield(())
    for await _ in release.stream { break }
    try Task.checkCancellation()
  }
  try await f.store.configureHealthModels(["synthetic-text"])
  let failed = try await f.store.admitSelectingAccount(f.command("token-overload"))
  let running = try await f.store.admitSelectingAccount(f.command("token-existing"))
  try await f.store.finalize(
    attempt: failed.attempt, evidence: nil,
    outcome: .init(failure: .upstreamUnavailable, atUnixSeconds: time.clock.unixSeconds))
  let command = try await f.command("token-waiter")
  let task = Task {
    await #expect(throws: AccountPacingRequired.self) {
      try await f.store.admitSelectingAccount(command)
    }
    try await f.store.waitForAccountPacing(seconds: 1)
    return try await f.store.admitSelectingAccount(command)
  }
  var arrivals = waiting.stream.makeAsyncIterator()
  _ = await arrivals.next()
  try await f.store.finalize(attempt: running.attempt, evidence: routeUsage)
  time.advance(seconds: 1)
  release.continuation.finish()
  await #expect(throws: ExecutionError.denied) { try await task.value }
  #expect(try await f.store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") } == 2)
  await f.close()
}

@Test(arguments: ["history", "object", "connection"])
func sessionPreferenceNeverOverridesOwnedHistoryOrConnection(kind: String) async throws {
  let f = try await RoutingFixture.make()
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  let b = try AccountRouteIdentity(id: "b", namespace: "synthetic/b")
  let seed = try await f.store.admitSelectingAccount(f.command("session-seed", preferred: a))
  let reference = ObjectBinding(type: "response", rawID: "synthetic-owned-response")
  try await f.store.bind(attempt: seed.attempt, object: reference)
  try await f.store.finalize(attempt: seed.attempt, evidence: routeUsage)
  let gateway = AccountPoolGateway(
    policy: f.policy, store: f.store, credentials: f.app, finalizer: RoutingFinalizer(),
    clock: testClock)
  try await gateway.execute(
    model: "synthetic-text", references: kind == "object" ? [reference] : [],
    affinityHints: kind == "history" ? [reference] : [],
    connection: kind == "connection" ? a : nil, preferred: b
  ) { context, work in
    #expect(context.admission.owner.identity == a.id)
    #expect(work.account.id == a.id)
    return routeUsage
  }
  await f.close()
}

private final class OwnerRefreshProbe: AccountDispatchRefreshing {
  let app: AccountCredentials
  let calls = Mutex<[String]>([])
  let beforeRefresh: @Sendable () async -> Void
  init(app: AccountCredentials, beforeRefresh: @escaping @Sendable () async -> Void = {}) {
    self.app = app
    self.beforeRefresh = beforeRefresh
  }
  var isAccepting: Bool { true }
  func refreshForDispatch(account: ManagedAccount) async throws -> ManagedAccount {
    calls.withLock { $0.append(account.id) }
    await beforeRefresh()
    let work = try await app.beginRefresh(id: account.id, revision: account.revision)
    return try await app.finishVerifiedRefresh(
      work, namespace: account.namespace,
      credential: AccountCredential(
        accessToken: "synthetic-refreshed", refreshToken: "synthetic-refresh",
        idToken: nil, expiresAtUnixSeconds: 2_000_000_000))
  }
}

private func expireRequiredOwner(_ f: RoutingFixture) async throws {
  let a = try #require(try await f.store.listAccounts().first { $0.id == "a" })
  let work = try await f.app.beginRefresh(id: a.id, revision: a.revision)
  _ = try await f.app.finishVerifiedRefresh(
    work, namespace: a.namespace,
    credential: AccountCredential(
      accessToken: "synthetic-expired", refreshToken: "synthetic-refresh",
      idToken: nil, expiresAtUnixSeconds: testClock.unixSeconds - 1))
}

@Test func requiredOwnerRefreshIsNotSkippedForHealthyAlternative() async throws {
  let f = try await RoutingFixture.make()
  try await expireRequiredOwner(f)
  let refresher = OwnerRefreshProbe(app: f.app)
  let gateway = AccountPoolGateway(
    policy: f.policy, store: f.store, credentials: f.app,
    finalizer: RoutingFinalizer(), refresher: refresher,
    clock: testClock)
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  try await gateway.execute(model: "synthetic-text", references: [], requiredAccount: a) {
    _, work in
    #expect(work.account.id == "a")
    return routeUsage
  }
  #expect(refresher.calls.withLock { $0 } == ["a"])
  await f.close()
}

@Test(arguments: [false, true])
func controlCooldownIsReadAfterOwnerRefresh(expired: Bool) async throws {
  let f = try await RoutingFixture.make()
  try await expireRequiredOwner(f)
  let a = try AccountRouteIdentity(id: "a", namespace: "synthetic/a")
  let now = Mutex(ContinuousClock.now)
  let health = ControlEndpointHealth(now: { now.withLock { $0 } })
  if expired { health.record(route: "search", account: a, seconds: 1) }
  let refresher = OwnerRefreshProbe(
    app: f.app,
    beforeRefresh: {
      if expired {
        now.withLock { $0 = $0.advanced(by: .seconds(2)) }
      } else {
        health.record(route: "search", account: a, seconds: 60)
      }
    })
  let gateway = AccountPoolGateway(
    policy: f.policy, store: f.store, credentials: f.app,
    finalizer: RoutingFinalizer(), refresher: refresher, clock: testClock)
  do {
    let work = try await gateway.authorizeControl(
      requiredAccount: a, cooldowns: { health.cooldowns(route: "search") })
    #expect(expired && work.account.id == "a")
  } catch let cooldown as AccountCooldownUnavailable {
    #expect(!expired && cooldown.retryAfter == 60)
  }
  await f.close()
}

@Test func controlRevocationWinsOverAllEndpointCooldowns() async throws {
  let f = try await RoutingFixture.make()
  let command = try await f.command("synthetic-control-candidates")
  _ = try await f.store.updateKey(
    id: f.policy.key.id, revision: f.policy.key.revision,
    enabled: false, policy: f.policy.key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await f.store.selectControlAccount(
      key: f.policy.key, candidates: command.candidates,
      preferred: nil,
      cooldowns: {
        Dictionary(uniqueKeysWithValues: command.candidates.map { ($0.identity, 60.0) })
      })
  }
  await f.close()
}

@Test func controlSelectionRechecksExpirationBeforeCooldown() async throws {
  let time = TestWallClock()
  let f = try await RoutingFixture.make(clock: time.clock)
  let key = try await f.store.setKeyExpiration(
    id: f.policy.key.id, revision: f.policy.key.revision,
    expiresAtUnixSeconds: time.clock.unixSeconds + 1)
  let command = try await f.command("synthetic-expiring-control")
  time.advance(seconds: 2)
  await #expect(throws: ExecutionError.keyExpired) {
    try await f.store.selectControlAccount(
      key: key, candidates: command.candidates, preferred: nil,
      cooldowns: {
        Dictionary(uniqueKeysWithValues: command.candidates.map { ($0.identity, 60.0) })
      })
  }
  await f.close()
}

@Test func quotaTrendPersistsSeparatesWindowsAndStartsOverAfterRecovery() async throws {
  let f = try await RoutingFixture.make()
  let account = try await f.store.accountCredential(id: "a").account
  let start: Int64 = 1_800_000_000
  let reset = start + 7200
  func quota(_ used: Double, resetAt: Int64) throws -> SubscriptionQuota {
    try .init(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: .init(usedPercent: used, durationSeconds: 18_000, resetsAtUnixSeconds: resetAt),
        secondary: .init(
          usedPercent: used / 2, durationSeconds: 604_800, resetsAtUnixSeconds: reset + 3600))
    ])
  }
  for (offset, used) in [(Int64(0), 25.0), (60, 26), (300, 40)] {
    _ = try await f.store.recordQuotaObservation(
      account: account, atUnixSeconds: start + offset,
      result: .success(quota(used, resetAt: reset + offset / 10)))
  }
  _ = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: start + 600, result: .failure(.unavailable))
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: testClock)
  let stored = try await reopened.quotaObservation(id: "a")
  #expect(stored.failure == .unavailable)
  #expect(stored.trend?.primary?.samples.map(\.at) == [start + 60, start + 300])
  #expect(stored.trend?.primary?.samples.map(\.remaining) == [74, 60])
  #expect(stored.trend?.secondary?.samples.map(\.remaining) == [87, 80])
  #expect(stored.trend?.primary?.reset == reset)

  let recovered = try await reopened.recordQuotaObservation(
    account: account, atUnixSeconds: start + 900, result: .success(quota(3, resetAt: reset)))
  #expect(recovered.trend?.primary?.samples.map(\.remaining) == [97])
  let rolled = try await reopened.recordQuotaObservation(
    account: account, atUnixSeconds: start + 1200,
    result: .success(quota(5, resetAt: reset + 1200)))
  #expect(rolled.trend?.primary?.samples.map(\.remaining) == [95])
  #expect(rolled.trend?.secondary?.samples.count == 2)
  await reopened.close()
  await f.close()
}

@Test func quotaTrendBudgetPreservesQuotaAndSparseWindow() async throws {
  let f = try await RoutingFixture.make()
  let account = try await f.store.accountCredential(id: "a").account
  let start: Int64 = 1_800_000_000
  let duration: Int64 = 604_800
  let reset = start + 172_800
  let extra = try (0..<16).map { index in
    try SubscriptionQuotaLimit(
      id: String(format: "%02d", index) + String(repeating: "x", count: 126),
      allowed: true, limitReached: false,
      primary: .init(
        usedPercent: 42.123456789012345, durationSeconds: duration, resetsAtUnixSeconds: reset),
      secondary: .init(
        usedPercent: 42.123456789012345, durationSeconds: duration, resetsAtUnixSeconds: reset))
  }
  for index in 0...288 {
    let at = start + Int64(index) * 300
    let main = try SubscriptionQuotaLimit(
      id: "codex", allowed: true, limitReached: false,
      primary: .init(
        usedPercent: Double(index) / 7.123456789, durationSeconds: duration,
        resetsAtUnixSeconds: reset),
      secondary: .init(
        usedPercent: Double(index) / 6.123456789, durationSeconds: duration,
        resetsAtUnixSeconds: index < 280 ? reset : reset + 3600))
    let quota = try SubscriptionQuota(limits: [main] + extra)
    _ = try await f.store.recordQuotaObservation(
      account: account, atUnixSeconds: at, result: .success(quota))
  }
  let observed = try await f.store.quotaObservation(id: "a")
  #expect(observed.quota?.limits.count == 17)
  let primary = try #require(observed.trend?.primary)
  #expect(primary.samples.count < 289)
  #expect(primary.samples.last?.at == start + 86_400)
  #expect(observed.trend?.secondary?.samples.count == 9)
  await f.close()
}

@Test func quotaCycleRetainsAWeekAndRestoresAcrossRestart() async throws {
  let f = try await RoutingFixture.make()
  let account = try await f.store.accountCredential(id: "a").account
  let start: Int64 = 1_800_000_000
  let duration: Int64 = 604_800
  let reset = start + duration
  for index in 0..<2016 {
    let used = Double(index) / 30
    let quota = try SubscriptionQuota(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: .init(usedPercent: used, durationSeconds: duration, resetsAtUnixSeconds: reset),
        secondary: nil)
    ])
    _ = try await f.store.recordQuotaObservation(
      account: account, atUnixSeconds: start + Int64(index) * 300, result: .success(quota))
  }
  let current = try #require(try await f.store.quotaCycleTrend(id: "a").primary)
  #expect(current.samples.count == 289)
  #expect(current.historySegments?.first?.first?.at == start)
  #expect(current.historySegments?.last?.last?.at == reset - 300)
  #expect(current.samples.last?.at == reset - 300)
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: testClock)
  #expect(try await reopened.quotaCycleTrend(id: "a").primary == current)
  let next = try SubscriptionQuota(limits: [
    .init(
      id: "codex", allowed: true, limitReached: false,
      primary: .init(
        usedPercent: 1, durationSeconds: duration, resetsAtUnixSeconds: reset + duration),
      secondary: nil)
  ])
  _ = try await reopened.recordQuotaObservation(
    account: account, atUnixSeconds: reset, result: .success(next))
  #expect(try await reopened.quotaCycleTrend(id: "a").primary?.samples.count == 1)
  _ = try await reopened.recordQuotaObservation(
    account: account, atUnixSeconds: reset + 600, result: .success(next))
  _ = try await reopened.recordQuotaObservation(
    account: account, atUnixSeconds: reset + 300, result: .success(next))
  #expect(try await reopened.quotaCycleTrend(id: "a").primary?.samples.first?.at == reset + 300)
  await reopened.close()
  await f.close()
}

@Test func quotaCycleMigratesLegacyHistoryAndSurvivesMetadataTrimming() async throws {
  let f = try await RoutingFixture.make()
  let account = try await f.store.accountCredential(id: "a").account
  let start: Int64 = 1_800_000_000
  let reset = start + 604_800
  func quota(_ used: Double) throws -> SubscriptionQuota {
    try .init(limits: [
      .init(
        id: "codex", allowed: true, limitReached: false,
        primary: .init(usedPercent: used, durationSeconds: 604_800, resetsAtUnixSeconds: reset),
        secondary: nil)
    ])
  }
  _ = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: start, result: .success(quota(10)))
  _ = try await f.store.recordQuotaObservation(
    account: account, atUnixSeconds: start + 300, result: .success(quota(11)))
  await f.store.close()
  try rawSQL(
    f.path,
    "DROP TABLE account_quota_cycle_samples; ALTER TABLE model_directory_routes DROP COLUMN reasoning_efforts; PRAGMA user_version=16"
  )
  let upgraded = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: testClock, allowStartupMigration: true)
  #expect(try await upgraded.quotaCycleTrend(id: "a").primary?.samples.count == 2)
  _ = try await upgraded.recordQuotaObservation(
    account: account, atUnixSeconds: start + 600, result: .success(quota(12)))
  #expect(try await upgraded.quotaCycleTrend(id: "a").primary?.samples.count == 3)
  try rawSQL(
    f.path,
    "UPDATE account_quota SET record_json=json_remove(record_json,'$.trend') WHERE account_id='a'")
  _ = try await upgraded.recordQuotaObservation(
    account: account, atUnixSeconds: start + 900, result: .success(quota(13)))
  #expect(try await upgraded.quotaCycleTrend(id: "a").primary?.samples.count == 4)
  let beforeFailure = try await upgraded.quotaCycleTrend(id: "a")
  try rawSQL(
    f.path,
    "CREATE TRIGGER fail_quota_cycle BEFORE INSERT ON account_quota_cycle_samples BEGIN SELECT RAISE(ABORT,'synthetic'); END"
  )
  await #expect(throws: ExecutionError.self) {
    try await upgraded.recordQuotaObservation(
      account: account, atUnixSeconds: start + 1200, result: .success(quota(14)))
  }
  #expect(try await upgraded.quotaCycleTrend(id: "a") == beforeFailure)
  try rawSQL(f.path, "DROP TRIGGER fail_quota_cycle")
  await upgraded.close()
  await f.close()
}

@Test func quotaCycleReadsTheMaximumSupportedYear() async throws {
  let f = try await RoutingFixture.make()
  let start: Int64 = 1_800_000_000
  let reset = start + 31_536_000
  try rawSQL(
    f.path,
    """
    WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<105119)
    INSERT INTO account_quota_cycle_samples(account_id,kind,bucket_epoch,at_epoch,remaining,reset_epoch,duration_seconds)
    SELECT 'a',0,(\(start)+i*300)/300,\(start)+i*300,'50',\(reset),31536000 FROM n
    """)
  let trend = try #require(try await f.store.quotaCycleTrend(id: "a").primary)
  #expect(trend.samples.count == 289)
  #expect(trend.historySegments?.first?.first?.at == start)
  #expect(trend.historySegments?.last?.last?.at == reset - 300)
  #expect(trend.historySegments?.flatMap { $0 }.count ?? 0 <= 1026)
  #expect(trend.historySampled == true)
  #expect(trend.samples.last?.at == reset - 300)
  await f.close()
}

@Test func quotaCycleBoundsManyGapsWithoutJoiningThem() async throws {
  let f = try await RoutingFixture.make()
  let start: Int64 = 1_800_000_000
  let reset = start + 31_536_000
  try rawSQL(
    f.path,
    """
    WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<1199)
    INSERT INTO account_quota_cycle_samples(account_id,kind,bucket_epoch,at_epoch,remaining,reset_epoch,duration_seconds)
    SELECT 'a',0,(\(start)+i*1200)/300,\(start)+i*1200,'50',\(reset),31536000 FROM n
    """)
  let trend = try #require(try await f.store.quotaCycleTrend(id: "a").primary)
  let segments = try #require(trend.historySegments)
  #expect(segments.count == 1024)
  #expect(segments.allSatisfy { $0.count == 1 })
  #expect(segments.first?.first?.at == start)
  #expect(segments.last?.last?.at == start + 1199 * 1200)
  #expect(trend.historyOmitted == true)
  await f.close()
}
