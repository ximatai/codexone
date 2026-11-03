import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func businessDayDefinitionChecksFloorOverflowAndSettings() throws {
  for minutes in [-720, 0, 480, 840] {
    let day = try BusinessDayDefinition(offsetMinutes: minutes)
    for epoch: Int64 in [-86401, -1, 0, 1, 1_800_000_000] {
      let start = try day.start(containing: epoch)
      let end = try day.end(containing: epoch)
      #expect(start <= epoch && epoch < end)
      #expect((start + day.offsetSeconds) % 86400 == 0)
      #expect(try day.isBoundary(start))
      #expect(
        try BusinessDayDefinition(
          setting: day.timezone == "UTC" ? "UTC" : String(day.timezone.dropFirst(3))) == day)
    }
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try BusinessDayDefinition.utc.start(containing: Int64.min)
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try BusinessDayDefinition.utc.end(containing: Int64.max)
  }
  #expect(throws: ExecutionError.invalidCommand) {
    try BusinessDayDefinition(offsetMinutes: 840).start(containing: Int64.max)
  }
}

private func businessAdmission(_ id: String, key: ManagedKey, window: String = "utc-day-0")
  -> ExecutionAdmission
{
  .init(
    attempt: id,
    owner: .init(principal: key.principal, key: key.id, namespace: "synthetic", identity: "i"),
    window: window, policyVersion: "p", pricingVersion: "p", reservedMicros: 0,
    keyRevision: key.revision, model: "synthetic-text")
}

@Test(arguments: [-720, 480, 840])
func businessDayAdmissionUsesTransactionTimeResetsLocallyAndReprojectsAfterRestart(minutes: Int)
  async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let day = try BusinessDayDefinition(offsetMinutes: minutes)
  let midnight = try day.end(containing: testUnixSeconds)
  let time = TestWallClock(midnight - 1)
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: time.clock, businessDay: day)
  let policy = try KeyPolicy(
    models: ["synthetic-text"],
    limits: .init(
      requests: nil, active: 2, unresolved: nil, budgetMicros: nil, unresolvedMicros: nil,
      tokens: 20))
  let key = try await store.createKey(
    id: "synthetic-key", principal: "p", digest: keyDigest("synthetic-business-day"), policy: policy
  )
  let prepared = businessAdmission(
    "after-midnight", key: key, window: try day.window(containing: midnight - 1))
  let first = try await store.admit(businessAdmission("before-midnight", key: key))
  #expect(first.window == "business-day-\(midnight - 86400)")
  try await store.finalize(attempt: first.attempt, evidence: usage(amount: 10))
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(businessAdmission("limited", key: key))
  }
  // Enqueue on the actual writer, advancing its clock before the admission can run.
  try await store.perform { _ in time.advance(seconds: 1) }
  let admitted = try await store.admit(prepared)
  #expect(admitted.window == "business-day-\(midnight)")
  #expect(try await store.snapshot(attempt: admitted.attempt).admission == admitted)
  try await store.finalize(attempt: admitted.attempt, evidence: usage(amount: 10))
  let reader = try await store.makeUsageReader()
  #expect(try await reader.keyUsage().startUnixSeconds == midnight)
  #expect(try await reader.keyUsage().keys.first?.tokens == 20)
  let buckets = try await reader.dailyUsage(days: 2, keyID: key.id, model: nil)
  #expect(buckets.map(\.requests) == [1, 1])
  let utcStart = (midnight / 86400 + 1) * 86400
  time.advance(seconds: utcStart - midnight)  // UTC midnight is inside this business day.
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(businessAdmission("utc-midnight", key: key))
  }
  await reader.close()
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: time.clock, businessDay: .utc)
  // The old local-day attempt occurred before the new UTC day, so switching needs no data work.
  let utc = try await reopened.admit(businessAdmission("changed-offset", key: key))
  #expect(utc.window == "business-day-\(utcStart)")
  #expect(
    try await reopened.snapshot(attempt: admitted.attempt).admission.window == admitted.window)
  await reopened.close()
}

@Test(arguments: [-720, 480, 840]) func businessDayRollupsKeepUTCDatesAndConserveTotals(
  minutes: Int
) async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let day = try BusinessDayDefinition(offsetMinutes: minutes)
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock, businessDay: day)
  let key = try await store.createKey(
    id: "rolled", principal: "p", digest: keyDigest("synthetic-rollup-day"),
    policy: .init(
      models: ["synthetic-text"],
      limits: .init(
        requests: nil, active: 2, unresolved: nil, budgetMicros: nil, unresolvedMicros: nil,
        tokens: 1)))
  let start = try day.start(containing: testUnixSeconds)
  let mapped = start + day.offsetSeconds
  let covering = try BusinessDayDefinition.utc.start(containing: start)
  try await store.perform { db in
    for (index, epoch) in Set([mapped, covering, mapped - 86400, mapped + 86400]).sorted()
      .enumerated()
    {
      try db.write(
        "INSERT INTO usage_daily(day_epoch,key_id,model,mode,outcome,failure,completeness,usage_unknown,requests,last_used_epoch,input_tokens,output_tokens,cached_tokens) VALUES(?,'rolled','synthetic-text','generation','succeeded','','complete',0,1,?,10,5,2)",
        [.number(epoch), .number(epoch + Int64(index))])
    }
  }
  let reader = try await store.makeUsageReader()
  let buckets = try await reader.dailyUsage(
    days: 3, keyID: key.id, model: nil, endUnixSeconds: start + 2 * 86400)
  #expect(buckets.map(\.requests) == [1, 1, 1])
  #expect(buckets.reduce(0) { $0 + ($1.metrics.inputTokens ?? 0) } == 30)
  let current = try await reader.keyUsage().keys[0]
  #expect(current.tokens == (mapped == covering ? 15 : 30))
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(businessAdmission("rollup-limited", key: key))
  }
  await reader.close()
  await store.close()
}

@Test func businessDayRestoreFreezePersistsInstantAndNeverShortensInheritance() throws {
  let day = try BusinessDayDefinition(offsetMinutes: 480)
  let end = try day.end(containing: testUnixSeconds)
  let record = RestoreRecord(
    id: UUID().uuidString, backupID: UUID().uuidString, snapshotUnixSeconds: testUnixSeconds - 1,
    restoredUnixSeconds: testUnixSeconds, inheritedUnresolvedRequests: 0,
    inheritedUnresolvedMicros: 0, dayFreezeUntilUnixSeconds: end)
  let baseline = try RestoreBaseline(
    restoreID: record.id, auditReference: "synthetic-audit", missingUnresolvedRequests: 0,
    missingUnresolvedMicros: 0, freezeUntilUnixSeconds: end)
  let next = try record.reconciling(baseline, at: testUnixSeconds, businessDay: day)
  #expect(!next.allowsAdmission(at: end - 1) && next.allowsAdmission(at: end))
  #expect(next.minimumReconciliationFreeze(at: end + 86400, businessDay: .utc) == end)
  let later = try day.end(containing: end + 1)
  #expect(record.minimumReconciliationFreeze(at: end + 1, businessDay: day) == later)
  #expect(throws: ExecutionError.conflict) {
    try record.reconciling(baseline, at: end + 1, businessDay: day)
  }
}

@Test func homeKeySummaryCacheUsesObservedUsageAndExactFailureExcludesDiagnostics() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let day = try BusinessDayDefinition(offsetMinutes: 480)
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock, businessDay: day)
  let key = try await store.createKey(
    id: "panel", principal: "p", digest: keyDigest("synthetic-panel"),
    policy: .init(
      models: ["synthetic-text"],
      limits: .init(
        requests: nil, active: 4, unresolved: nil, budgetMicros: nil, unresolvedMicros: nil)))
  for (id, kind, evidence) in [
    (
      "known", ExecutionOutcome.Kind.succeeded,
      Optional(
        UsageEvidence(
          revision: 1, inputTokens: 100, outputTokens: 10, cachedTokens: 25, images: 0,
          estimatedMicros: 0, completeness: .complete))
    ),
    ("failure", .failed, nil), ("cancelled", .cancelled, nil),
  ] {
    try await store.admit(businessAdmission(id, key: key))
    try await store.finalize(
      attempt: id, evidence: evidence,
      outcome: .init(
        failure: kind == .failed
          ? .upstreamUnavailable : kind == .cancelled ? .clientCancelled : nil,
        atUnixSeconds: testUnixSeconds))
  }
  try await store.recordRejection(
    requestID: "diagnostic", keyID: key.id, model: "synthetic-text", mode: .generation,
    failure: .localCapacity)
  let reader = try await store.makeUsageReader()
  let summary = try await reader.keyUsage()
  let row = try #require(summary.keys.first)
  #expect(row.admitted == 3 && row.failed == 1 && row.cancelled == 1)
  #expect(row.tokens == 110 && row.tokenUsageIncomplete)
  #expect(row.inputTokens == 100 && row.cachedTokens == 25 && row.cacheUsageIncomplete)
  let failures = try await reader.queryUsage(
    .init(
      startUnixSeconds: summary.startUnixSeconds, endUnixSeconds: summary.startUnixSeconds + 86400,
      keyID: key.id, outcome: .failed))
  #expect(failures.totals.admitted == row.failed && failures.totals.rejected == 0)
  #expect(failures.rows.map(\.id) == ["failure"])
  let combined = try await reader.queryUsage(
    .init(
      startUnixSeconds: summary.startUnixSeconds, endUnixSeconds: summary.startUnixSeconds + 86400,
      keyID: key.id, failedOnly: true, outcome: .failed))
  #expect(combined.totals.failed == 1 && combined.totals.rejected == 0)
  #expect(throws: ExecutionError.invalidCommand) {
    try UsageAdminAPI.parse("/api/usage?start=1800000000&end=1800003600&outcome=cancelled")
  }
  await reader.close()
  await store.close()
}
