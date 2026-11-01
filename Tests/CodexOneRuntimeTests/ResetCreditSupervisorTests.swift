import CodexOneCore
import CodexOneRuntime
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private actor ResetProviderProbe: AccountResetCreditProvider {
  var failsList = false
  var listed = 0
  var intents: [ResetCreditIntent] = []
  var blocked = false
  var cancelled = 0
  var code = ResetCreditCode.nothingToReset
  var list: ResetCreditList
  init(now: Int64) throws {
    func credit(_ id: String, _ offset: Int64?, status: String = "available") throws -> ResetCredit
    {
      try .init(
        id: id, type: "synthetic", status: status,
        grantedAt: "2026-01-01T00:00:00Z",
        expiresAt: offset.map { Date(timeIntervalSince1970: Double(now + $0)).ISO8601Format() },
        title: nil, description: nil)
    }
    list = try .init(
      credits: [
        credit("outside", 25 * 3600), credit("later", 3 * 3600), credit("earliest", 3600),
        credit("no-expiry", nil), credit("expired", -1),
        credit("unavailable", 60, status: "future"),
      ], availableCount: 4)
  }
  func setListFailure(_ value: Bool) { failsList = value }
  func setBlocked() { blocked = true }
  func setCode(_ code: ResetCreditCode) { self.code = code }
  func resetCredits(_ work: AccountObservationWork) async throws -> ResetCreditList {
    listed += 1
    if failsList { throw QuotaObservationFailure.unavailable }
    return list
  }
  func consumeResetCredit(_ work: AccountObservationWork, intent: ResetCreditIntent) async throws
    -> ResetCreditResult
  {
    intents.append(intent)
    do { while blocked { try await Task.sleep(for: .milliseconds(5)) } } catch {
      cancelled += 1
      throw error
    }
    return try .init(code: code)
  }
}

@Test(.timeLimit(.minutes(1)))
func resetCreditCycleDefaultOffEarliestOnePerCycleAndNothingToResetRetries() async throws {
  let time = Mutex<Int64>(1_800_000_000)
  let clock = WallClock { Double(time.withLock { $0 }) }
  let f = try await RefreshFixture.make(count: 4, clock: clock)
  let provider = try ResetProviderProbe(now: clock.unixSeconds)
  let supervisor = try ResetCreditSupervisor(
    store: f.store, credentials: f.app, provider: provider, clock: clock)
  let owner = Task { try await GatewayRuntime(services: [supervisor]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { supervisor.isAccepting }
    _ = try await f.store.setAccountMode(id: f.accounts[0].id, revision: 1, mode: .enabled)
    try await supervisor.scheduleCycle()
    #expect(await provider.listed == 0)
    for index in 0..<4 {
      let a = try await f.store.accountCredential(id: f.accounts[index].id).account
      _ = try await f.store.setResetCreditSettings(
        id: a.id, revision: a.revision, settings: .init(autoUseBeforeExpiry: true))
    }
    // Disabled, draining and reauthorization-required accounts never trigger automatic work.
    _ = try await f.store.setAccountMode(id: f.accounts[2].id, revision: 2, mode: .draining)
    let ready = try await f.store.setAccountMode(id: f.accounts[3].id, revision: 2, mode: .enabled)
    _ = try await f.store.beginAccountRefresh(
      id: ready.id, revision: ready.revision, intent: "synthetic-refresh")
    _ = try await f.store.failAccountRefresh(
      id: ready.id, credentialVersion: 1, intent: "synthetic-refresh", authorizationRequired: true)
    try await supervisor.scheduleCycle()
    #expect(await provider.intents.count == 1)
    #expect(await provider.intents.first?.creditID == "earliest")
    #expect(try await f.store.resetCreditState(id: f.accounts[0].id).intent == nil)
    try await supervisor.scheduleCycle()
    #expect(await provider.intents.count == 1)
    time.withLock { $0 += 1800 }
    try await supervisor.scheduleCycle()
    let intents = await provider.intents
    #expect(intents.count == 2 && intents[0].requestID != intents[1].requestID)
    #expect(try #require(intents.last).creditID == "earliest")
    await provider.setCode(.reset)
    time.withLock { $0 += 1800 }
    try await supervisor.scheduleCycle()
    #expect(await provider.intents.last?.creditID == "later")
    let reader = try await f.store.makeUsageReader()
    #expect(
      try await reader.attentionItems(now: clock.unixSeconds).contains {
        $0.kind == "reset_credits" && $0.detail["code"] == .string("reset")
      })
    await reader.close()
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
func resetCreditOwnerBoundsSingleFlightAndCancelsAwaitedNetworkOnShutdown() async throws {
  let f = try await RefreshFixture.make(count: 5)
  let provider = try ResetProviderProbe(now: 1_800_000_000)
  await provider.setBlocked()
  let supervisor = try ResetCreditSupervisor(store: f.store, credentials: f.app, provider: provider)
  let owner = Task { try await GatewayRuntime(services: [supervisor]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { supervisor.isAccepting }
    let pending = f.accounts.prefix(4).map { a in
      Task { try await supervisor.consumeResetCredit(id: a.id, creditID: nil) }
    }
    try await awaitRefreshCondition { await provider.intents.count == 4 }
    await #expect(throws: ExecutionError.conflict) {
      try await supervisor.consumeResetCredit(id: f.accounts[0].id, creditID: nil)
    }
    await #expect(throws: ExecutionError.capacity) {
      try await supervisor.consumeResetCredit(id: f.accounts[4].id, creditID: nil)
    }
    owner.cancel()
    _ = await owner.result
    for request in pending { #expect(try await request.value.code == .unknown) }
    #expect(supervisor.activeOperations == 0 && !supervisor.isAccepting)
    #expect(await provider.cancelled == 4)
    #expect(try await f.store.resetCreditState(id: f.accounts[0].id).intent != nil)
  } catch {
    owner.cancel()
    _ = await owner.result
    await f.close()
    throw error
  }
  await f.close()
}

@Test func resetCreditLeadWindowIncludesBoundaryButNeverExpiredMissingOrUnknownStatus() throws {
  let now: Int64 = 1_800_000_000
  func item(_ id: String, _ expiry: Int64?, _ status: String = "available") throws -> ResetCredit {
    try .init(
      id: id, type: "future", status: status, grantedAt: "2026-01-01T00:00:00Z",
      expiresAt: expiry.map { Date(timeIntervalSince1970: Double($0)).ISO8601Format() }, title: nil,
      description: nil)
  }
  let list = try ResetCreditList(
    credits: [
      item("at-boundary", now + 3600), item("outside", now + 3601), item("expired", now),
      item("none", nil), item("unknown", now + 1, "future"),
    ], availableCount: 3)
  #expect(list.expiringCredit(now: now, leadHours: 1)?.id == "at-boundary")
  #expect(list.expiringCredit(now: now + 3601, leadHours: 1) == nil)
}

@Test(.timeLimit(.minutes(1)))
func resetCreditAutomaticUnknownHintsReuseIDAndFailuresAreConsecutive() async throws {
  let time = Mutex<Int64>(1_800_000_000)
  let clock = WallClock { Double(time.withLock { $0 }) }
  let f = try await RefreshFixture.make(clock: clock)
  let a = try await f.store.setAccountMode(id: f.accounts[0].id, revision: 1, mode: .enabled)
  _ = try await f.store.setResetCreditSettings(
    id: a.id, revision: a.revision, settings: .init(autoUseBeforeExpiry: true))
  let provider = try ResetProviderProbe(now: clock.unixSeconds)
  await provider.setCode(.unknown)
  let supervisor = try ResetCreditSupervisor(
    store: f.store, credentials: f.app, provider: provider, clock: clock)
  let owner = Task { try await GatewayRuntime(services: [supervisor]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition {
      try await f.store.resetCreditState(id: a.id).intent != nil && supervisor.activeOperations == 0
    }
    let original = try #require(await f.store.resetCreditState(id: a.id).intent)
    let reader = try await f.store.makeUsageReader()
    #expect(
      try await reader.attentionItems(now: clock.unixSeconds).contains {
        $0.kind == "reset_credits" && $0.detail["code"] == .string("unknown")
      })
    await provider.setCode(.alreadyRedeemed)
    time.withLock { $0 += 1800 }
    supervisor.observedResetCredits(id: a.id)
    try await awaitRefreshCondition {
      try await f.store.resetCreditState(id: a.id).intent == nil && supervisor.activeOperations == 0
    }
    #expect(await provider.intents.last?.requestID == original.requestID)
    #expect(try await f.store.resetCreditState(id: a.id).lastAutoResetAt == nil)
    await provider.setListFailure(true)
    for _ in 0..<3 {
      time.withLock { $0 += 1800 }
      try await supervisor.scheduleCycle()
    }
    #expect(try await f.store.resetCreditState(id: a.id).failures == 3)
    #expect(
      try await reader.attentionItems(now: clock.unixSeconds).contains {
        $0.kind == "reset_credits" && $0.detail["code"] == .string("repeated_failure")
      })
    await reader.close()
    await provider.setListFailure(false)
    time.withLock { $0 += 1800 }
    try await supervisor.scheduleCycle()
    #expect(try await f.store.resetCreditState(id: a.id).failures == 0)
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
