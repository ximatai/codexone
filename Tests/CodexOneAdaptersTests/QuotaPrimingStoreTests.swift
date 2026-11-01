import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private struct PrimingFixture {
  let path: String
  let time: TestWallClock
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  static func make() async throws -> Self {
    let path = try temporaryExecutionPath()
    let time = TestWallClock()
    let store = try await SQLiteExecutionStore.open(
      path: path, limits: syntheticLimits, clock: time.clock)
    let app = AccountCredentials(
      store: store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32)),
      clock: time.clock)
    let a = try await app.importVerified(
      id: "account", namespace: "synthetic/account",
      credential: .init(
        accessToken: "synthetic", refreshToken: "synthetic", idToken: nil,
        expiresAtUnixSeconds: 2_000_000_000))
    _ = try await store.setAccountMode(id: a.id, revision: a.revision, mode: .enabled)
    try await store.configureHealthModels(["synthetic-text"])
    return .init(path: path, time: time, store: store, app: app)
  }
  func observation(active: Bool = false) async throws {
    let a = try await store.accountCredential(id: "account").account
    let windows = try [Int64(18000), 604800].map { duration in
      try SubscriptionQuotaWindow(
        usedPercent: active ? 1 : 0, durationSeconds: duration,
        resetsAtUnixSeconds: time.clock.unixSeconds + (active ? 1 : duration),
        resetAfterSeconds: active ? 1 : duration)
    }
    _ = try await store.recordQuotaObservation(
      account: a, atUnixSeconds: time.clock.unixSeconds,
      result: .success(
        .init(limits: [
          .init(
            id: "codex", allowed: true, limitReached: false, primary: windows[0],
            secondary: windows[1])
        ])))
  }
  func enable() async throws {
    let a = try await store.accountCredential(id: "account").account
    _ = try await store.setQuotaPrimingSettings(
      id: a.id, revision: a.revision, settings: .init(enabled: true, model: "synthetic-text"))
  }
  func command(_ id: String, priming: Bool = true) async throws -> ExecutionAdmission {
    let work = try await app.prepareDispatch(id: "account", continuation: false)
    return .init(
      attempt: id,
      owner: .init(
        principal: priming ? QuotaPrimingIdentity.principal : "p",
        key: priming ? QuotaPrimingIdentity.principal : "k", namespace: work.account.namespace,
        identity: "account"),
      window: "utc-day-\(time.clock.utcDay)", policyVersion: "priming-v1", pricingVersion: "1",
      reservedMicros: 1,
      mode: priming ? .priming : .generation, model: "synthetic-text",
      accountSnapshot: work.snapshot)
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}
@Test func quotaPrimingAtomicBothWindowsRestartBarrierAndUsageLedger() async throws {
  let f = try await PrimingFixture.make()
  try await f.observation()
  await #expect(throws: ExecutionError.denied) { try await f.store.admit(f.command("disabled")) }
  try await f.enable()
  let command = try await f.command("first")
  try await f.store.admit(command)
  await #expect(throws: ExecutionError.denied) { try await f.store.admit(f.command("duplicate")) }
  let state = try await f.store.quotaPrimingState(id: "account")
  #expect(state.windows.count == 2 && state.windows.values.allSatisfy(\.awaitingActive))
  #expect(
    try await f.store.perform { try $0.scalar("SELECT COUNT(*) FROM quota_priming_events") } == 1)
  let usage = UsageEvidence(
    revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0, estimatedMicros: 2,
    completeness: .complete)
  try await f.store.finalize(
    attempt: command.attempt, evidence: usage,
    outcome: .init(failure: nil, atUnixSeconds: f.time.clock.unixSeconds))
  let snapshot = try await f.store.snapshot(attempt: "first")
  #expect(snapshot.admission.executionMode == .priming && snapshot.admission.keyRevision == nil)
  #expect(
    snapshot.admission.owner.principal == QuotaPrimingIdentity.principal && snapshot.usage == usage)
  #expect(try await f.store.quotaPrimingState(id: "account").lastResult == "success")
  let reader = try await f.store.makeUsageReader()
  let hour = f.time.clock.unixSeconds / 3600 * 3600
  let report = try await reader.queryUsage(
    .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600, mode: .priming))
  #expect(report.rows.first?.principal == QuotaPrimingIdentity.principal)
  #expect(report.rows.first?.mode == .priming)
  await reader.close()
  await f.store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, clock: f.time.clock)
  f.time.advance(seconds: 4000)
  let a = try await reopened.accountCredential(id: "account").account
  _ = try await reopened.recordQuotaObservation(
    account: a, atUnixSeconds: f.time.clock.unixSeconds,
    result: .success(
      .init(limits: [
        .init(
          id: "codex", allowed: true, limitReached: false,
          primary: .init(
            usedPercent: 0, durationSeconds: 18000,
            resetsAtUnixSeconds: f.time.clock.unixSeconds + 18000, resetAfterSeconds: 18000),
          secondary: nil)
      ])))
  #expect(
    try await reopened.quotaPrimingState(id: "account").eligible(
      reopened.quotaObservation(id: "account"), now: f.time.clock.unixSeconds
    ).isEmpty)
  await reopened.close()
  await f.close()
}
@Test func quotaPrimingFailureBackoffStopsAndRaisesAttentionAfterThreeWindows() async throws {
  let f = try await PrimingFixture.make()
  try await f.enable()
  for index in 0..<3 {
    try await f.observation()
    let command = try await f.command("failure-\(index)")
    try await f.store.admit(command)
    try await f.store.finalize(
      attempt: command.attempt, evidence: nil,
      outcome: .init(failure: .indeterminate, atUnixSeconds: f.time.clock.unixSeconds))
    f.time.advance(seconds: 1)
    try await f.observation(active: true)
    f.time.advance(seconds: 1)
    try await f.observation()
    await #expect(throws: ExecutionError.denied) {
      try await f.store.admit(f.command("early-\(index)"))
    }
    f.time.advance(seconds: 3600)
  }
  let state = try await f.store.quotaPrimingState(id: "account")
  #expect(state.failures == 3 && !state.settings.enabled && state.attention == "repeated_failure")
  let reader = try await f.store.makeUsageReader()
  #expect(
    try await reader.attentionItems(now: f.time.clock.unixSeconds).contains {
      $0.kind == "quota_priming"
    })
  await reader.close()
  await f.close()
}
@Test func quotaPrimingSkipsCoolingFullAndStaleAccountAndStorageFailureRollsBack() async throws {
  for scenario in ["cooling", "full", "stale", "write"] {
    let f = try await PrimingFixture.make()
    try await f.enable()
    try await f.observation()
    let command = try await f.command("blocked")
    if scenario == "cooling" {
      try await f.store.perform { db in
        try db.write(
          "INSERT INTO account_model_health VALUES(?,?,?,?)",
          [
            .text("account"), .text("synthetic-text"), .number(testUnixSeconds + 3600),
            .text("rate_limited"),
          ])
      }
    } else if scenario == "full" {
      for i in 0..<16 { try await f.store.admit(f.command("active-\(i)", priming: false)) }
    } else if scenario == "stale" {
      let a = try await f.store.accountCredential(id: "account").account
      _ = try await f.store.setAccountMode(id: a.id, revision: a.revision, mode: .draining)
    } else {
      try rawSQL(
        f.path,
        "CREATE TRIGGER fail_priming BEFORE INSERT ON quota_priming_events BEGIN SELECT RAISE(ABORT,'synthetic'); END"
      )
    }
    await #expect(throws: (any Error).self) { try await f.store.admit(command) }
    #expect(
      try await f.store.perform { try $0.scalar("SELECT COUNT(*) FROM quota_priming_events") } == 0)
    #expect(try await f.store.quotaPrimingState(id: "account").windows.isEmpty)
    await f.close()
  }
}

@Test func quotaPrimingBackupRestoreKeepsBarrierAndDisablesAutomation() async throws {
  let f = try await PrimingFixture.make()
  try await f.enable()
  try await f.observation()
  try await f.store.admit(f.command("pending"))
  await f.store.close()
  let root = (f.path as NSString).deletingLastPathComponent
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: f.path, destination: root + "/bundle", protection: cipher, clock: f.time.clock)
  _ = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/bundle", path: root + "/restored/core.sqlite", protection: cipher,
    clock: f.time.clock)
  let restored = try await SQLiteExecutionStore.open(
    path: root + "/restored/core.sqlite", limits: syntheticLimits, clock: f.time.clock)
  let state = try await restored.quotaPrimingState(id: "account")
  #expect(
    !state.settings.enabled && state.windows.count == 2
      && state.windows.values.allSatisfy(\.awaitingActive))
  #expect(state.lastResult == "unknown")
  #expect(try await restored.snapshot(attempt: "pending").state == .unknown)
  await restored.close()
  await f.close()
}

@Test func quotaPrimingParametersUseLowestDeclaredEffortAndRespectProviderVerbositySupport() throws
{
  for supported in [true, false] {
    var model = SingleIdentityConfiguration.Model(
      id: "synthetic-text", inputMicrosPerMillion: 1, outputMicrosPerMillion: 1)
    model.upstream = .object([
      "supported_reasoning_levels": .array([
        .object(["effort": .string("high")]), .object(["effort": .string("none")]),
        .object(["effort": .string("low")]),
      ]), "support_verbosity": .bool(supported),
    ])
    let request = try SubscriptionWindowPriming.request(model: model, message: "<hello>")
    let body = try request.preparedDocument(contract: .codexSubscription, nativeWebSocket: false)
    #expect(body["reasoning"]?["effort"] == .string("none"))
    #expect((body["text"] != nil) == supported)
    #expect(body["max_output_tokens"] == nil && body["store"] == .bool(false))
    #expect(body["tools"]?.array?.isEmpty == true)
    #expect(body["input"]?.array?.first?["content"] == .string("<hello>"))
  }
}
