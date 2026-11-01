import CSQLite
import CodexOneCore
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

@Test func governanceUnknownDoesNotBlockAndAccountConcurrencyIsBounded() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  // A single synthetic transaction makes a large unknown population; no provider calls.
  try await store.perform { db in
    try db.transaction {
      for i in 0..<2000 {
        try SQLiteExecutionStore.insertAttempt(db, admission("unknown-\(i)"), state: "unknown")
      }
    }
  }
  for i in 0..<16 { try await store.admit(admission("active-\(i)")) }
  await #expect(throws: ExecutionError.accountConcurrency) {
    try await store.admit(admission("over"))
  }
  try await store.finalize(attempt: "active-0", evidence: nil)
  try await store.admit(admission("after-release"))
  // Neither the legacy global daily budget nor requests/unresolved prevent admission.
  let reader = try await store.makeUsageReader()
  let headroom = try await reader.governanceHeadroom(now: testUnixSeconds)
  #expect(headroom.accounts.first?.current == 16 && headroom.accounts.first?.peak24Hours == 16)
  #expect(headroom.capacities.first?.current == 2017)
  #expect(
    try await store.perform { try $0.scalar("SELECT COUNT(*) FROM account_concurrency") } <= 16)
  await reader.close()
  await store.close()
}

@Test func governanceExpiryIsBatchedAuditedIdempotentAndAcceptsLateEvidence() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let now = testUnixSeconds
  try await store.perform { db in
    try db.transaction {
      for i in 0..<202 {
        try SQLiteExecutionStore.insertAttempt(db, admission("expiry-\(i)"), state: "unknown")
      }
      try db.write("UPDATE attempts SET unknown_since_epoch=?", [.number(now - 86400)])
      try db.write(
        "UPDATE attempts SET unknown_since_epoch=? WHERE id='expiry-201'", [.number(now - 86399)])
    }
  }
  try await store.finalize(attempt: "expiry-200", evidence: usage())
  try await store.maintainExecutions(now: now)
  #expect(
    try await store.perform {
      try $0.scalar("SELECT COUNT(*) FROM attempts WHERE closed_unknown_at_epoch IS NOT NULL")
    } == 100)
  await store.close()  // no in-memory cursor; next owner continues safely
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  try await reopened.maintainExecutions(now: now)
  try await reopened.maintainExecutions(now: now)
  #expect(try await reopened.snapshot(attempt: "expiry-201").state == .unknown)
  #expect(
    try await reopened.perform {
      try $0.scalar("SELECT COUNT(*) FROM maintenance_events WHERE action='release_unknown'")
    } == 2)
  #expect(try await reopened.snapshot(attempt: "expiry-0").state == .closedUnknown)
  try await reopened.finalize(attempt: "expiry-0", evidence: usage(complete: false))
  #expect(try await reopened.snapshot(attempt: "expiry-0").state == .closedUnknown)
  try await reopened.finalize(attempt: "expiry-0", evidence: usage(revision: 2))
  #expect(try await reopened.snapshot(attempt: "expiry-0").state == .settled)
  let reader = try await reopened.makeUsageReader()
  let day = now / 86400 * 86400
  let report = try await reader.queryUsage(
    .init(startUnixSeconds: day, endUnixSeconds: day + 86400))
  #expect(report.totals.usageUnknown == 200 && report.totals.unknownReasons["unspecified"] == 200)
  await reader.close()
  await reopened.close()
}

@Test func governanceRetentionRollsUpAtomicallyPreservesNullsAndProtectsUnresolved() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let now = testUnixSeconds
  let oldDay = now / 86400 * 86400 - 91 * 86400
  for id in ["complete-old", "unknown-old", "intent-old", "closed-old", "boundary-old"] {
    try await store.admit(admission(id))
    if id != "intent-old" {
      try await store.finalize(attempt: id, evidence: id == "complete-old" ? usage() : nil)
    }
  }
  _ = try await store.releaseUnknown(
    beforeUnixSeconds: now + 1, expectedCount: 3)
  try await store.perform { db in
    try db.write("UPDATE attempts SET created_at_epoch=?", [.number(oldDay)])
    try db.write(
      "UPDATE attempts SET state='unknown',closed_unknown_at_epoch=NULL,unknown_since_epoch=? WHERE id='unknown-old'",
      [.number(now)])
    try db.write(
      "UPDATE attempts SET created_at_epoch=? WHERE id='boundary-old'",
      [.number(now - ExecutionLimits.detailRetentionSeconds)])
  }
  let query = try UsageQuery(startUnixSeconds: oldDay, endUnixSeconds: oldDay + 86400)
  let reader = try await store.makeUsageReader()
  let before = try await reader.read { try SQLiteUsageReader.daily($0, query) }
  // A delete failure must roll back aggregate creation as well.
  try await store.perform {
    try $0.exec(
      "CREATE TRIGGER fail_retention BEFORE DELETE ON attempts BEGIN SELECT RAISE(ABORT,'synthetic'); END"
    )
  }
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.maintainExecutions(now: now)
  }
  #expect(try await store.perform { try $0.scalar("SELECT COUNT(*) FROM usage_daily") } == 0)
  await reader.close()
  await store.close()
  let retryStore = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let retryReader = try await retryStore.makeUsageReader()
  try await retryStore.perform { try $0.exec("DROP TRIGGER fail_retention") }
  try await retryStore.maintainExecutions(now: now)
  try await retryStore.maintainExecutions(now: now)
  let after = try await retryReader.read { try SQLiteUsageReader.daily($0, query) }
  #expect(
    after[0].requests == before[0].requests
      && after[0].metrics.inputTokens == before[0].metrics.inputTokens)
  // Restart converts the old live intent to unknown.
  #expect(after[0].usageUnknown == before[0].usageUnknown + 1)
  #expect(try await retryStore.snapshot(attempt: "intent-old").state == .unknown)
  #expect(try await retryStore.snapshot(attempt: "unknown-old").state == .unknown)
  #expect(try await retryStore.snapshot(attempt: "boundary-old").state == .closedUnknown)
  #expect(
    try await retryStore.perform { try $0.scalar("SELECT SUM(requests) FROM usage_daily") } == 2)
  // The exact cutoff remains detailed; one second later it is eligible for atomic rollup.
  try await retryStore.maintainExecutions(now: now + 1)
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await retryStore.snapshot(attempt: "boundary-old")
  }
  #expect(try await retryStore.snapshot(attempt: "unknown-old").state == .unknown)
  #expect(try await retryStore.snapshot(attempt: "intent-old").state == .unknown)
  await retryReader.close()
  await retryStore.close()
}

@Test func governanceAlertBoundariesAreObservationsOnly() {
  #expect(AttentionRules.executions(admitted: 50, failed: 0, unknown: 9, since: nil).isEmpty)
  #expect(AttentionRules.executions(admitted: 51, failed: 0, unknown: 10, since: nil).isEmpty)
  #expect(
    AttentionRules.executions(admitted: 50, failed: 0, unknown: 10, since: nil).first?.severity
      == "warning")
  #expect(
    AttentionRules.accountCapacity(id: "synthetic", peak: 12, recent: 59, baseline: 0).isEmpty)
  #expect(
    AttentionRules.accountCapacity(id: "synthetic", peak: 13, recent: 60, baseline: 12).count == 2)
  #expect(
    AttentionRules.accountCapacity(id: "synthetic", peak: 0, recent: 60, baseline: 13).isEmpty)
  #expect(
    AttentionRules.capacity(.init(name: "daily_requests", current: 79, limit: 100, blocking: false))
      .isEmpty)
  #expect(
    AttentionRules.capacity(.init(name: "daily_requests", current: 80, limit: 100, blocking: false))
      .first?.severity == "warning")
  #expect(
    AttentionRules.capacity(
      .init(name: "daily_requests", current: 101, limit: 100, blocking: false)
    ).first?.detail["exceeded"] == .bool(true))
}

@Test func governanceV9MigrationBacksUpBeforeVacuumAndRollsBackSchemaFailure() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  try await store.admit(admission("pre-migration"))
  await store.close()
  try rawSQL(
    path,
    removeGovernanceSchema
      + "PRAGMA user_version=9; PRAGMA auto_vacuum=NONE; VACUUM; CREATE TABLE usage_daily(synthetic INTEGER);"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: testClock)
  }
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteExecutionStore.migrate(path: path)
  }
  let failed = try SQLiteConnection(readOnlyPath: path)
  #expect(try failed.scalar("PRAGMA user_version") == 9)
  #expect(
    try failed.scalar(
      "SELECT COUNT(*) FROM pragma_table_info('attempts') WHERE name='unknown_since_epoch'") == 0)
  failed.shutdown()
  let backups = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.contains(".pre-v11-") && $0.hasSuffix(".sqlite")
  }
  #expect(backups.count == 1)
  let backup = try SQLiteConnection(readOnlyPath: directory + "/" + backups[0])
  #expect(try backup.scalar("PRAGMA auto_vacuum") == 0)
  #expect(try backup.scalar("PRAGMA user_version") == 9)
  #expect(try backup.scalar("SELECT COUNT(*) FROM attempts WHERE state='intent'") == 1)
  backup.shutdown()
  try rawSQL(path, "DROP TABLE usage_daily")
  try await SQLiteExecutionStore.migrate(path: path)
  let migrated = try SQLiteConnection(path: path)
  #expect(try migrated.scalar("PRAGMA user_version") == 11)
  #expect(try migrated.scalar("PRAGMA auto_vacuum") == 2)
  migrated.shutdown()
}

@Test func governanceBindingExpiryProtectsLiveContinuationsAndDoesNotDeleteUnknown() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let now = testUnixSeconds
  let object = ObjectBinding(type: "response", rawID: "synthetic-response")
  try await store.admit(admission("binding-live"))
  try await store.bind(attempt: "binding-live", object: object)
  let oldObject = ObjectBinding(type: "response", rawID: "synthetic-old-response")
  try await store.admit(admission("binding-old"))
  try await store.bind(attempt: "binding-old", object: oldObject)
  try await store.finalize(attempt: "binding-old", evidence: usage())
  try await store.perform {
    try $0.write("UPDATE bindings SET expires_at_epoch=?", [.number(now + 1)])
    try $0.write(
      "UPDATE attempts SET created_at_epoch=? WHERE id='binding-old'", [.number(now - 91 * 86400)])
  }
  try await store.maintainExecutions(now: now)
  #expect(try await store.resolve(principal: "p", object: object).identity == "i")
  #expect(try await store.resolve(principal: "p", object: oldObject).identity == "i")
  #expect(try await store.snapshot(attempt: "binding-old").state == .settled)
  try await store.finalize(attempt: "binding-live", evidence: nil)
  try await store.maintainExecutions(now: now + 1)
  await #expect(throws: ExecutionError.unknownObject) {
    try await store.resolve(principal: "p", object: object)
  }
  #expect(try await store.snapshot(attempt: "binding-live").state == .unknown)
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await store.snapshot(attempt: "binding-old")
  }
  await store.close()
}

@Test func governanceIncrementalVacuumActuallyReclaimsPagesAndBlockedPressurePauses() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let available = Synchronization.Mutex(Int64(2_000_000_000))
  let policy = try StorageSpacePolicy(
    reserveBytes: 1_048_576, stopBytes: 2_097_152, resumeBytes: 3_145_728, optionalBytes: 4_194_304)
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, storagePolicy: policy,
    available: { _ in available.withLock { $0 } }, clock: testClock)
  let now = testUnixSeconds
  try await store.perform { db in
    try db.exec(
      "CREATE TABLE synthetic_pages(payload BLOB); INSERT INTO synthetic_pages VALUES(zeroblob(1048576)); DELETE FROM synthetic_pages;"
    )
    try SQLiteExecutionStore.insertAttempt(db, admission("blocked-expiry"), state: "unknown")
    try db.write("UPDATE attempts SET unknown_since_epoch=?", [.number(now - 86400)])
  }
  let before = try await store.perform { try $0.scalar("PRAGMA page_count") }
  available.withLock { $0 = 1_048_576 }
  try await store.maintainStorage()
  await #expect(throws: ExecutionError.storagePressure) {
    try await store.maintainExecutions(now: now)
  }
  #expect(try await store.snapshot(attempt: "blocked-expiry").state == .unknown)
  available.withLock { $0 = 2_000_000_000 }
  try await store.maintainStorage()
  for _ in 0..<4 { try await store.maintainExecutions(now: now) }
  #expect(try await store.perform { try $0.scalar("PRAGMA page_count") } < before)
  #expect(try await store.snapshot(attempt: "blocked-expiry").state == .closedUnknown)
  await store.close()
}

@Test func governanceReaderMeasuresRateMedianPeakWindowAndQuotaRankingWithUnknownImages()
  async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let now = testUnixSeconds
  let envelope =
    "v1." + String(repeating: "a", count: 32) + "."
    + Data(repeating: 7, count: 28).base64EncodedString()
  let account = try await store.createVerifiedAccount(
    id: "synthetic-account", namespace: "synthetic", envelope: envelope)
  let quota = try SubscriptionQuota(limits: [
    .init(
      id: "codex", allowed: true, limitReached: false,
      primary: .init(usedPercent: 98, durationSeconds: 18000, resetsAtUnixSeconds: now + 1),
      secondary: nil)
  ])
  _ = try await store.recordQuotaObservation(
    account: account, atUnixSeconds: now, result: .success(quota))
  try await store.perform { db in
    try db.transaction {
      for day in 0...7 {
        for i in 0..<(day == 0 ? 60 : 12) {
          let id = "rate-\(day)-\(i)"
          try SQLiteExecutionStore.insertAttempt(
            db, admission(id, identity: "synthetic-account"), state: "settled")
          try db.write(
            "UPDATE attempts SET created_at_epoch=?,usage_json=? WHERE id=?",
            [.number(now - Int64(day) * 86400 - 1), .text(try encode(usage())), .text(id)])
        }
      }
      let native = UsageEvidence(
        revision: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, images: 1,
        estimatedMicros: 0, completeness: .partial, nativeImages: true)
      let images = ExecutionAdmission(
        attempt: "native-unknown",
        owner: .init(
          principal: "synthetic", key: "image-key", namespace: "synthetic",
          identity: "synthetic-account"), window: "w", policyVersion: "1", pricingVersion: "1",
        reservedMicros: 1)
      try SQLiteExecutionStore.insertAttempt(db, images, state: "unknown")
      try db.write(
        "UPDATE attempts SET usage_json=?,created_at_epoch=? WHERE id='native-unknown'",
        [.text(try encode(native)), .number(now - 18000)])
      try db.write(
        "INSERT INTO account_concurrency VALUES('synthetic','synthetic-account',?,16)",
        [.number(now - 86400)])
    }
  }
  let reader = try await store.makeUsageReader()
  let items = try await reader.attentionItems(now: now)
  #expect(items.first { $0.kind == "account_rate_surge" }?.detail["median"]?.integer == 12)
  #expect(items.first { $0.kind == "account_concurrency_high" }?.detail["peak"]?.integer == 16)
  let ranking = items.first { $0.kind == "quota_high" }?.detail["keyRanking"]?.string ?? ""
  #expect(ranking.contains("image-key：费用未知"))
  #expect(!ranking.contains("image-key：$0.000000"))
  let later = try await reader.attentionItems(now: now + 1)
  #expect(!later.contains { $0.kind == "account_concurrency_high" })
  let laterRanking = later.first { $0.kind == "quota_high" }?.detail["keyRanking"]?.string ?? ""
  #expect(!laterRanking.contains("image-key"))
  await reader.close()
  await store.close()
}

@Test func governanceOnlyExplicitKeyUnresolvedAndBudgetLimitsRejectTheirOwnKey() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  for (id, limit) in [
    (
      "pending-key",
      ExecutionLimits(
        requests: nil, active: nil, unresolved: 2, budgetMicros: nil, unresolvedMicros: nil)
    ),
    (
      "budget-key",
      ExecutionLimits(
        requests: nil, active: nil, unresolved: nil, budgetMicros: 5, unresolvedMicros: nil)
    ),
    (
      "unlimited-key",
      ExecutionLimits(
        requests: nil, active: nil, unresolved: nil, budgetMicros: nil, unresolvedMicros: nil)
    ),
  ] {
    _ = try await store.createKey(
      id: id, principal: "synthetic",
      digest: String(
        repeating: id == "pending-key" ? "a" : id == "budget-key" ? "b" : "c", count: 64),
      policy: KeyPolicy(models: ["synthetic-text"], limits: limit))
  }
  func command(_ attempt: String, key: String) -> ExecutionAdmission {
    .init(
      attempt: attempt,
      owner: .init(principal: "synthetic", key: key, namespace: "synthetic", identity: "i"),
      window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 6, keyRevision: 1,
      model: "synthetic-text")
  }
  for i in 0..<2 {
    try await store.admit(command("key-unknown-\(i)", key: "pending-key"))
    try await store.finalize(attempt: "key-unknown-\(i)", evidence: nil)
  }
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(command("pending-rejected", key: "pending-key"))
  }
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(command("budget-rejected", key: "budget-key"))
  }
  try await store.admit(command("other-key-accepted", key: "unlimited-key"))
  #expect(protocolFailure(ExecutionError.accountConcurrency).status == 429)
  await store.close()
}

@Test func governancePeakFrontierCompactsRepeatedSamplesAcrossRestartAndRelease() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  try await store.admit(admission("peak-active"))
  let now = testUnixSeconds
  try await store.perform { db in
    for offset in 1...40 {
      try db.write(
        "INSERT INTO account_concurrency VALUES('synthetic','i',?,1)",
        [.number(now - Int64(offset))])
    }
  }
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  #expect(
    try await reopened.perform { try $0.scalar("SELECT COUNT(*) FROM account_concurrency") } == 1)
  try await reopened.admit(admission("peak-release"))
  try await reopened.finalize(attempt: "peak-release", evidence: nil)
  let reader = try await reopened.makeUsageReader()
  #expect(try await reader.governanceHeadroom(now: now + 1).accounts.first?.peak24Hours == 1)
  #expect(
    try await reopened.perform { try $0.scalar("SELECT COUNT(*) FROM account_concurrency") } == 1)
  await reader.close()
  await reopened.close()
}

@Test func governanceArchivedKeyLastUsePreservesZeroAndMissingTimes() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  _ = try await store.createKey(
    id: "key", principal: "p", digest: String(repeating: "b", count: 64),
    policy: .init(models: ["m"], limits: syntheticLimits))
  _ = try await store.createKey(
    id: "unused", principal: "p", digest: String(repeating: "c", count: 64),
    policy: .init(models: ["m"], limits: syntheticLimits))
  try await store.admit(admission("epoch-zero"))
  try await store.finalize(attempt: "epoch-zero", evidence: usage())
  try await store.perform { try $0.exec("UPDATE attempts SET created_at_epoch=0") }
  let reader = try await store.makeUsageReader()
  #expect(try await reader.keyUsage().keys.first?.lastUsedAtUnixSeconds == 0)
  try await store.maintainExecutions(now: testUnixSeconds)
  let archived = try await reader.keyUsage().keys
  let daily = try await reader.dailyUsage(days: 1, keyID: "key", model: nil, endUnixSeconds: 86400)
  #expect(daily.first?.requests == 1 && daily.first?.metrics.inputTokens == 12)
  #expect(archived.first?.lastUsedAtUnixSeconds == 0)
  #expect(archived.last?.lastUsedAtUnixSeconds == nil)
  #expect(try await store.perform { try $0.scalar("SELECT COUNT(*) FROM attempts") } == 0)
  await reader.close()
  await store.close()
}
