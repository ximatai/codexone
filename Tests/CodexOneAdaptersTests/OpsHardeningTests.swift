import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func unknownReleaseIsCASBoundedAuditedAndPreservesMissingUsage() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let reader = try await store.makeUsageReader()
  for id in ["old", "boundary", "intent", "settled"] {
    try await store.admit(admission(id))
    if id != "intent" {
      try await store.finalize(
        attempt: id, evidence: id == "settled" ? usage() : nil,
        outcome: .init(failure: .clientCancelled, atUnixSeconds: 100))
    }
  }
  try await store.perform { db in
    try db.write("UPDATE attempts SET created_at_epoch=100")
    try db.write("UPDATE attempts SET created_at_epoch=99 WHERE id='old'")
  }
  await #expect(throws: ExecutionError.conflict) {
    try await store.releaseUnknown(beforeUnixSeconds: 100, expectedCount: 2)
  }
  #expect(try await store.snapshot(attempt: "old").state == .unknown)
  #expect(try await store.releaseUnknown(beforeUnixSeconds: 100, expectedCount: 1) == 1)
  #expect(try await store.snapshot(attempt: "old").state == .settled)
  #expect(try await store.snapshot(attempt: "old").usage == nil)
  #expect(try await store.snapshot(attempt: "boundary").state == .unknown)
  #expect(try await store.snapshot(attempt: "intent").state == .intent)
  #expect(try await store.snapshot(attempt: "settled").usage == usage())
  let report = try await reader.queryUsage(.init(startUnixSeconds: 0, endUnixSeconds: 3600))
  #expect(report.totals.unavailable == 3 && report.totals.unknown == 1)
  #expect(report.rows.first { $0.id == "old" }?.completeness == nil)
  #expect(report.rows.first { $0.id == "old" }?.failure == .clientCancelled)
  let audit = try await store.perform { db in
    try db.rows("SELECT record_json FROM maintenance_events WHERE action='release_unknown'") {
      String(cString: sqlite3_column_text($0, 0))
    }
  }
  #expect(audit.count == 1)
  #expect(try JSONValue.decode(Data(audit[0].utf8))["released"]?.integer == 1)
  #expect(try await store.releaseUnknown(beforeUnixSeconds: 0, expectedCount: 0) == 0)
  await reader.close()
  await store.close()
}

@Test func releaseRollbackIncludesAuditFailure() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  for id in ["first", "second"] {
    try await store.admit(admission(id))
    try await store.finalize(attempt: id, evidence: nil)
  }
  try rawSQL(
    path,
    "CREATE TRIGGER fail_release_audit BEFORE INSERT ON maintenance_events BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
  )
  await #expect(throws: ExecutionError.self) {
    try await store.releaseUnknown(beforeUnixSeconds: Int64.max, expectedCount: 2)
  }
  #expect(try await store.snapshot(attempt: "first").state == .unknown)
  #expect(try await store.snapshot(attempt: "second").state == .unknown)
  await store.close()
}

@Test func unresolvedCapacityRejectsAtBoundaryAndReleaseRestoresAdmission() async throws {
  for sameIdentity in [false, true] {
    let path = try temporaryExecutionPath()
    let store = try await SQLiteExecutionStore.open(
      path: path,
      limits: .init(requests: 100, active: 10, unresolved: 2, budgetMicros: 1000),
      unresolvedCapacity: 2)
    for i in 0..<2 {
      try await store.admit(
        admission("a\(i)", principal: "p\(i)", identity: sameIdentity ? "same" : "i\(i)"))
      try await store.finalize(attempt: "a\(i)", evidence: nil)
    }
    await #expect(throws: ExecutionError.denied) {
      try await store.admit(
        admission("rejected", principal: "other", identity: sameIdentity ? "same" : "other"))
    }
    #expect(try await store.releaseUnknown(beforeUnixSeconds: Int64.max, expectedCount: 2) == 2)
    try await store.admit(admission("accepted", principal: "other", identity: "same"))
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}

@Test func attentionUnresolvedPercentageBoundaries() {
  for (count, severity) in [(49, nil), (50, "warning"), (79, "warning"), (80, "critical")]
    as [(Int64, String?)]
  {
    let item = AttentionRules.executions(
      admitted: 0, failed: 0, unknown: 3, since: 1, unresolved: count, limit: 100
    ).first
    #expect(item?.severity == severity)
    if severity != nil {
      #expect(item?.detail["count"]?.integer == 3)
      #expect(item?.detail["unresolvedCount"]?.integer == count)
      #expect(item?.detail["limit"]?.integer == 100)
    }
  }
}

@Test func globalAndIdentityCapacityGrowWhilePrincipalAndPersistedLimitsStayUnchanged() async throws
{
  for sameIdentity in [false, true] {
    let path = try temporaryExecutionPath()
    let limits = ExecutionLimits(requests: 100, active: 10, unresolved: 32, budgetMicros: 1000)
    let store = try await SQLiteExecutionStore.open(path: path, limits: limits)
    for i in 0..<35 {
      try await store.admit(
        admission("a\(i)", principal: "p\(i)", identity: sameIdentity ? "same" : "i\(i)"))
      try await store.finalize(attempt: "a\(i)", evidence: nil)
    }
    #expect(store.unresolvedCapacity == 1024)
    for i in 0..<32 {
      try await store.admit(admission("p\(i)", principal: "unchanged", identity: "other\(i)"))
      try await store.finalize(attempt: "p\(i)", evidence: nil)
    }
    await #expect(throws: ExecutionError.denied) {
      try await store.admit(admission("principal-full", principal: "unchanged", identity: "fresh"))
    }
    await store.close()
    let reopened = try await SQLiteExecutionStore.open(path: path, limits: limits)
    #expect(reopened.limits.unresolved == 32 && reopened.unresolvedCapacity == 1024)
    await reopened.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}

@Test func releasePreservesPartialEvidenceButReportsUnavailableAndDoesNotReopenOnLateEvidence()
  async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let reader = try await store.makeUsageReader()
  try await store.admit(admission("partial"))
  try await store.finalize(attempt: "partial", evidence: usage(amount: 2, complete: false))
  #expect(try await store.releaseUnknown(beforeUnixSeconds: Int64.max, expectedCount: 1) == 1)
  #expect(try await store.snapshot(attempt: "partial").usage == usage(amount: 2, complete: false))
  let hour = Int64(Date().timeIntervalSince1970) / 3600 * 3600
  let report = try await reader.queryUsage(
    .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
  #expect(
    report.totals.unavailable == 1 && report.totals.partial == 0 && report.totals.unknown == 0)
  #expect(report.rows.first?.completeness == nil && report.rows.first?.metrics.inputTokens == 2)
  try await store.finalize(
    attempt: "partial", evidence: usage(revision: 2, amount: 3, complete: false))
  #expect(try await store.snapshot(attempt: "partial").state == .settled)
  try await store.finalize(attempt: "partial", evidence: usage(revision: 3, amount: 4))
  let complete = try await reader.queryUsage(
    .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
  #expect(complete.totals.complete == 1 && complete.totals.unavailable == 0)
  await reader.close()
  await store.close()
}

@Test func attentionIncludesRecoveredMissingExposureWithoutOfferingItForRelease() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path,
    limits: .init(requests: 100, active: 10, unresolved: 100, budgetMicros: 1000),
    unresolvedCapacity: 100)
  let reader = try await store.makeUsageReader()
  try await store.admit(admission("intent"))
  let record = RestoreRecord(
    id: UUID().uuidString, backupID: UUID().uuidString,
    snapshotUnixSeconds: 100, restoredUnixSeconds: 200,
    inheritedUnresolvedRequests: 49, inheritedUnresolvedMicros: 0)
  let payload = try encode(record)
  try await store.perform { db in
    try db.write("UPDATE maintenance_state SET restore_json=? WHERE id=1", [.text(payload)])
  }
  let item = try await reader.attentionItems(now: 300).first { $0.kind == "unresolved_executions" }
  #expect(item?.severity == "warning")
  #expect(item?.detail["unresolvedCount"]?.integer == 50)
  #expect(item?.detail["count"]?.integer == 0)
  #expect(item?.detail["limit"]?.integer == 100)
  await reader.close()
  await store.close()
}
