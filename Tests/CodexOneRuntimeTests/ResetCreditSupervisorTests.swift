import CodexOneCore
import CodexOneRuntime
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private actor ResetProviderProbe: AccountResetCreditProvider {
  var failsList = false
  var failsConsume = false
  var afterList: (@Sendable () -> Void)?
  func setAfterList(_ action: @escaping @Sendable () -> Void) { afterList = action }
  var attemptTimes: [Int64] = []
  var listTimes: [Int64] = []
  var clock = testClock
  func setClock(_ clock: WallClock) { self.clock = clock }
  func setConsumeFailure() { failsConsume = true }
  func setExpiry(now: Int64, offset: Int64, status: String = "available") throws {
    list = try .init(
      credits: [
        .init(
          id: "timed-credit", type: "synthetic", status: status,
          grantedAt: "2026-01-01T00:00:00Z",
          expiresAt: Date(timeIntervalSince1970: Double(now + offset)).ISO8601Format(),
          title: nil, description: nil)
      ], availableCount: 1)
  }
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
    listTimes.append(clock.unixSeconds)
    if failsList { throw QuotaObservationFailure.unavailable }
    afterList?()
    return list
  }
  func consumeResetCredit(_ work: AccountObservationWork, intent: ResetCreditIntent) async throws
    -> ResetCreditResult
  {
    intents.append(intent)
    attemptTimes.append(clock.unixSeconds)
    if failsConsume { throw QuotaObservationFailure.unavailable }
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
  #expect(list.expiringCredit(now: now, leadMinutes: 60)?.id == "at-boundary")
  #expect(list.expiringCredit(now: now + 3601, leadMinutes: 60) == nil)
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
    for step in 0..<4 {
      time.withLock { $0 += step == 0 ? 1800 : 60 }
      try await supervisor.scheduleCycle()
    }
    #expect(try await f.store.resetCreditState(id: a.id).failures == 4)
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

@Test(.timeLimit(.minutes(1)))
func resetCreditHintForRemovedAccountKeepsRuntimeRunning() async throws {
  let time = Mutex<Int64>(1_800_000_000)
  let clock = WallClock { Double(time.withLock { $0 }) }
  let f = try await RefreshFixture.make(count: 1, clock: clock)
  let provider = try ResetProviderProbe(now: clock.unixSeconds)
  let supervisor = try ResetCreditSupervisor(
    store: f.store, credentials: f.app, provider: provider, clock: clock)
  let owner = Task { try await GatewayRuntime(services: [supervisor]).run(handleSignals: false) }
  do {
    try await awaitRefreshCondition { supervisor.isAccepting }
    #expect(ManagedAccount.validID("removed-account"))
    supervisor.observedResetCredits(id: "removed-account")
    try await Task.sleep(for: .milliseconds(200))
    #expect(supervisor.isAccepting)
    #expect(await provider.listed == 0)
  } catch {
    owner.cancel()
    throw error
  }
  owner.cancel()
  _ = try? await owner.value
  await f.close()
}

private final class ResetWakeProbe: Sendable {
  let ticks: AsyncStream<Void>
  let tick: AsyncStream<Void>.Continuation
  let delays = Mutex<[Int64]>([])
  let cancelled = Mutex(false)
  init() { (ticks, tick) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
  func sleep(_ seconds: Int64) async throws {
    delays.withLock { $0.append(seconds) }
    for await _ in ticks { break }
    if Task.isCancelled {
      cancelled.withLock { $0 = true }
      throw CancellationError()
    }
  }
}

private struct ResetTimingFixture {
  let f: RefreshFixture
  let time: TestWallClock
  let provider: ResetProviderProbe
  let supervisor: ResetCreditSupervisor
  let wake: ResetWakeProbe
  let owner: Task<Void, Error>
  var id: String { f.accounts[0].id }
  static func make(
    minutes: Int = 4, retries: Int = 3, expiry: Int64 = 600,
    code: ResetCreditCode = .unknown, pending: Bool = false
  ) async throws -> Self {
    let time = TestWallClock()
    let f = try await RefreshFixture.make(clock: time.clock)
    let account = try await f.store.setAccountMode(
      id: f.accounts[0].id, revision: 1, mode: .enabled)
    _ = try await f.store.setResetCreditSettings(
      id: account.id, revision: account.revision,
      settings: .init(autoUseBeforeExpiry: true, leadMinutes: minutes, retryCount: retries))
    if pending {
      let current = try await f.store.accountCredential(id: account.id).account
      let attempt = try await f.store.beginResetCreditAttempt(
        account: current,
        creditID: "timed-credit", automatic: true)
      try await f.store.finishResetCreditAttempt(
        id: account.id, attempt: attempt,
        result: .init(code: .unknown))
      time.advance(seconds: 60)
    }
    let provider = try ResetProviderProbe(now: time.clock.unixSeconds)
    await provider.setClock(time.clock)
    try await provider.setExpiry(now: time.clock.unixSeconds, offset: expiry)
    await provider.setCode(code)
    let wake = ResetWakeProbe()
    let supervisor = try ResetCreditSupervisor(
      store: f.store, credentials: f.app,
      provider: provider, clock: time.clock, sleep: { try await wake.sleep($0) })
    let owner = Task { try await supervisor.run() }
    let value = Self(
      f: f, time: time, provider: provider, supervisor: supervisor, wake: wake, owner: owner)
    try await awaitRefreshCondition { !wake.delays.withLock { $0.isEmpty } }
    return value
  }
  func cycle(after seconds: Int64) async throws {
    time.advance(seconds: seconds)
    try await supervisor.scheduleCycle()
  }
  func close() async {
    owner.cancel()
    _ = await owner.result
    await f.close()
  }
}

@Test(.timeLimit(.minutes(1)))
func resetCreditSingleTimerWakesAtMinuteDueAndShutdownCancelsSleep() async throws {
  let t = try await ResetTimingFixture.make(expiry: 375, code: .reset)
  do {
    #expect(await t.provider.intents.isEmpty)
    #expect(t.wake.delays.withLock { $0.last } == 60)
    for delta in [Int64(60), 60, 14] {
      let count = t.wake.delays.withLock { $0.count }
      t.time.advance(seconds: delta)
      t.wake.tick.yield(())
      try await awaitRefreshCondition { t.wake.delays.withLock { $0.count > count } }
      #expect(await t.provider.intents.isEmpty)
      #expect(await t.provider.listed == 1)
    }
    #expect(t.wake.delays.withLock { $0.last } == 1)
    t.time.advance(seconds: 1)
    t.wake.tick.yield(())
    try await awaitRefreshCondition {
      await t.provider.intents.count == 1 && t.supervisor.activeOperations == 0
    }
    #expect(await t.provider.attemptTimes == [testUnixSeconds + 135])
    #expect(await t.provider.listed == 2)
  } catch {
    await t.close()
    throw error
  }
  await t.close()
  #expect(t.wake.cancelled.withLock { $0 })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func resetCreditAutomaticRetriesEveryMinuteBoundedAndReusesUnknownID(transportFailure: Bool)
  async throws
{
  let t = try await ResetTimingFixture.make(expiry: 240)
  do {
    // The first attempt has already completed as unknown; subsequent transport errors are unknown too.
    if transportFailure { await t.provider.setConsumeFailure() }
    for _ in 0..<3 {
      try await t.cycle(after: 59)
      let count = await t.provider.intents.count
      try await t.cycle(after: 1)
      #expect(await t.provider.intents.count == count + 1)
    }
    try await t.cycle(after: 60)
    try await t.cycle(after: 1800)
    let intents = await t.provider.intents
    #expect(intents.count == 4)
    #expect(Set(intents.map(\.requestID)).count == 1)
    #expect(await t.provider.attemptTimes == (0..<4).map { testUnixSeconds + Int64($0 * 60) })
    let reader = try await t.f.store.makeUsageReader()
    let attention = try await reader.attentionItems(now: t.time.clock.unixSeconds)
    #expect(
      attention.contains {
        $0.kind == "reset_credits" && $0.detail["code"] == .string("repeated_failure")
          && $0.detail["attempts"] == .number(4)
      })
    await reader.close()
    #expect(
      try await t.f.store.perform {
        try $0.scalar("SELECT COUNT(*) FROM reset_credit_events WHERE action='consume'")
      } == 4)
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}

@Test(
  .timeLimit(.minutes(1)),
  arguments: [ResetCreditCode.reset, .alreadyRedeemed, .noCredit, .nothingToReset])
func resetCreditFinalCodesStopRetriesAndNothingToResetWaitsForLaterCycle(code: ResetCreditCode)
  async throws
{
  let t = try await ResetTimingFixture.make(minutes: 60, expiry: 3000, code: code)
  do {
    for _ in 0..<4 { try await t.cycle(after: 60) }
    #expect(await t.provider.intents.count == 1)
    if code == .nothingToReset {
      await t.provider.setCode(.unknown)
      try await t.cycle(after: 1560)
      for _ in 0..<3 { try await t.cycle(after: 60) }
      #expect(await t.provider.intents.count == 5)
      #expect(try await t.f.store.resetCreditState(id: t.id).failures == 4)
    }
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [Int64(-1), 0, 60, 119])
func resetCreditOverdueRestartAndRetriesNeverReachExpiry(expiry: Int64) async throws {
  let t = try await ResetTimingFixture.make(expiry: expiry, pending: true)
  do {
    #expect(await t.provider.intents.count == (expiry > 0 ? 1 : 0))
    for _ in 0..<5 { try await t.cycle(after: 60) }
    #expect(await t.provider.intents.count == (expiry > 60 ? 2 : expiry > 0 ? 1 : 0))
    #expect(await t.provider.attemptTimes.allSatisfy { $0 < testUnixSeconds + 60 + expiry })
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}

@Test(.timeLimit(.minutes(1)))
func resetCreditDueFreshListMustStillBeAvailableAndSettingsRecomputeImmediately() async throws {
  let t = try await ResetTimingFixture.make(expiry: 600, code: .reset)
  do {
    let saved = try await t.f.store.resetCreditState(id: t.id)
    _ = try await t.f.store.setResetCreditSettings(
      id: t.id, revision: saved.revision,
      settings: .init(autoUseBeforeExpiry: true, leadMinutes: 10, retryCount: 0))
    t.supervisor.observedResetCredits(id: t.id)
    try await awaitRefreshCondition {
      await t.provider.intents.count == 1 && t.supervisor.activeOperations == 0
    }
    #expect(await t.provider.attemptTimes == [testUnixSeconds])
  } catch {
    await t.close()
    throw error
  }
  await t.close()
  let changed = try await ResetTimingFixture.make(expiry: 375)
  do {
    try await changed.provider.setExpiry(now: testUnixSeconds, offset: 375, status: "used")
    try await changed.cycle(after: 135)
    #expect(await changed.provider.intents.isEmpty)
  } catch {
    await changed.close()
    throw error
  }
  await changed.close()
}

@Test(.timeLimit(.minutes(1)))
func resetCreditDueListFailureRetriesOnMinuteWithoutExtendingKnownExpiry() async throws {
  let t = try await ResetTimingFixture.make(expiry: 375)
  do {
    await t.provider.setListFailure(true)
    try await t.cycle(after: 135)
    for _ in 0..<3 {
      let count = await t.provider.listed
      try await t.cycle(after: 59)
      #expect(await t.provider.listed == count)
      try await t.cycle(after: 1)
      #expect(await t.provider.listed == count + 1)
    }
    try await t.cycle(after: 60)
    #expect(await t.provider.listed == 5)  // one discovery plus four failed attempts
    #expect(await t.provider.intents.isEmpty)
    #expect(try await t.f.store.resetCreditState(id: t.id).failures == 4)
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1, 5])
func resetCreditConfiguredRetryCountIsAdditionalAttempts(retries: Int) async throws {
  let t = try await ResetTimingFixture.make(minutes: 10, retries: retries, expiry: 600)
  do {
    for _ in 0..<(retries + 2) { try await t.cycle(after: 60) }
    #expect(await t.provider.intents.count == retries + 1)
    #expect(try await t.f.store.resetCreditState(id: t.id).failures == retries + 1)
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}

@Test(.timeLimit(.minutes(1)))
func resetCreditExpiryCrossedDuringFreshListNeverSends() async throws {
  let t = try await ResetTimingFixture.make(expiry: 375)
  do {
    await t.provider.setAfterList { t.time.advance(seconds: 240) }
    try await t.cycle(after: 135)
    #expect(t.time.clock.unixSeconds == testUnixSeconds + 375)
    #expect(await t.provider.intents.isEmpty)
    #expect(try await t.f.store.resetCreditState(id: t.id).intent == nil)
  } catch {
    await t.close()
    throw error
  }
  await t.close()
}
