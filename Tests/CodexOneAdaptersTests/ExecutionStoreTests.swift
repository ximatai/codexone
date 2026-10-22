import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

func temporaryExecutionPath() throws -> String {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("core.sqlite").path
}
let syntheticLimits = ExecutionLimits(requests: 100, active: 4, unresolved: 4, budgetMicros: 100)
func admission(
  _ id: String, principal: String = "p", identity: String = "i", window: String = "w",
  reserved: Int64 = 10
) -> ExecutionAdmission {
  .init(
    attempt: id,
    owner: .init(principal: principal, key: "key", namespace: "synthetic", identity: identity),
    window: window, policyVersion: "policy-v1", pricingVersion: "price-v1", reservedMicros: reserved
  )
}
func usage(revision: Int64 = 1, amount: Int64 = 12, complete: Bool = true)
  -> UsageEvidence
{
  .init(
    revision: revision, inputTokens: amount, outputTokens: amount, cachedTokens: 0,
    images: 0, estimatedMicros: amount, completeness: complete ? .complete : .partial)
}
func rawSQL(_ path: String, _ sql: String) throws {
  var db: OpaquePointer?
  guard sqlite3_open(path, &db) == SQLITE_OK else { throw ExecutionError.storageUnavailable }
  defer { sqlite3_close(db) }
  guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
    throw ExecutionError.storageUnavailable
  }
}

@Test func admissionCompetitionAndDuplicateIDsAreAtomic() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let accepted = await withTaskGroup(of: Bool.self) { group in
    for index in 0..<16 {
      group.addTask {
        do {
          try await store.admit(admission("a\(index)"))
          return true
        } catch { return false }
      }
    }
    var count = 0
    for await value in group { if value { count += 1 } }
    return count
  }
  #expect(accepted == 4)
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(admission("extra", window: "new-window"))
  }
  await store.close()
}

@Test func idBarrierAndPrincipalIsolationSurviveReopen() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let object = ObjectBinding(type: "response", rawID: "response1")
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a"))
  await #expect(throws: ExecutionError.unknownObject) {
    try await store.resolve(principal: "p", object: object)
  }
  try await store.bind(attempt: "a", object: object)
  try await store.bind(attempt: "a", object: object)
  await #expect(throws: ExecutionError.unknownObject) {
    try await store.resolve(principal: "other", object: object)
  }
  try await store.admit(admission("b"))
  await #expect(throws: ExecutionError.conflict) {
    try await store.bind(attempt: "b", object: object)
  }
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.snapshot(attempt: "a").state == .unknown)
  #expect(try await reopened.resolve(principal: "p", object: object).identity == "i")
  await reopened.close()
}

@Test func cumulativeSettlementIsIdempotentAndLateEvidenceIsMerged() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a"))
  try await store.finalize(attempt: "a", evidence: usage(complete: false))
  #expect(try await store.snapshot(attempt: "a").state == .unknown)
  try await store.finalize(attempt: "a", evidence: nil)
  try await store.finalize(attempt: "a", evidence: usage(revision: 2, amount: 30))
  try await store.finalize(attempt: "a", evidence: usage(revision: 2, amount: 30))
  try await store.finalize(attempt: "a", evidence: usage(complete: false))
  try await store.finalize(attempt: "a", evidence: usage(revision: 3, amount: 110))
  #expect(try await store.snapshot(attempt: "a").usage?.estimatedMicros == 110)
  #expect(try await store.snapshot(attempt: "a").state == .settled)
  await #expect(throws: ExecutionError.conflict) {
    try await store.finalize(attempt: "a", evidence: usage(revision: 3, amount: 111))
  }
  await #expect(throws: ExecutionError.conflict) {
    try await store.finalize(attempt: "a", evidence: usage(revision: 4, amount: 10))
  }
  await #expect(throws: ExecutionError.denied) { try await store.admit(admission("b")) }
  await store.close()
}

@Test func unknownExecutionRetainsReservationsAcrossRestart() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a", reserved: 100))
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.snapshot(attempt: "a").state == .unknown)
  await #expect(throws: ExecutionError.denied) { try await reopened.admit(admission("b")) }
  await reopened.close()
}

@Test func schemaAndInstanceLockFailClosed() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await #expect(throws: ExecutionError.instanceLocked) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  await store.close()
  try rawSQL(path, "PRAGMA user_version=999")
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  try rawSQL(path, "PRAGMA user_version=4")
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await reopened.close()
  let legacy = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (legacy as NSString).deletingLastPathComponent)
  }
  try rawSQL(legacy, "CREATE TABLE legacy(id INTEGER)")
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: legacy, limits: syntheticLimits)
  }
}

@Test func failedTransactionsDoNotDispatchOrExposeBindings() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a"))
  try rawSQL(
    path,
    "CREATE TRIGGER fail_bind BEFORE INSERT ON bindings BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
  )
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.bind(attempt: "a", object: .init(type: "response", rawID: "r"))
  }
  await #expect(throws: ExecutionError.unknownObject) {
    try await store.resolve(principal: "p", object: .init(type: "response", rawID: "r"))
  }
  try rawSQL(
    path,
    "CREATE TRIGGER fail_finalize BEFORE UPDATE ON attempts BEGIN SELECT RAISE(ABORT,'synthetic fault'); END"
  )
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.finalize(attempt: "a", evidence: usage())
  }
  #expect(try await store.snapshot(attempt: "a").state == .intent)
  try rawSQL(path, "DROP TRIGGER fail_finalize; DROP TRIGGER fail_bind")
  await store.close()
  let recovered = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await recovered.snapshot(attempt: "a").state == .unknown)
  try await recovered.finalize(attempt: "a", evidence: usage())
  #expect(try await recovered.snapshot(attempt: "a").state == .settled)
  await recovered.close()
}

@Test func actualReadOnlyFailurePreservesIntentAndStopsAdmission() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let original = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await original.admit(admission("a"))
  await original.close()
  let connection = try SQLiteConnection(path: path)
  try connection.exec("PRAGMA query_only=ON")
  let store = SQLiteExecutionStore(connection: connection, limits: syntheticLimits)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.finalize(attempt: "a", evidence: usage())
  }
  #expect(try await store.snapshot(attempt: "a").state == .intent)
  // Even after write access returns, failed persistence needs explicit restart/recovery before new admission.
  try connection.exec("PRAGMA query_only=OFF")
  await #expect(throws: ExecutionError.storageUnavailable) { try await store.admit(admission("b")) }
  await store.close()
  let recovered = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await recovered.snapshot(attempt: "a").state == .unknown)
  await recovered.close()
}

@Test func unresolvedMoneyAndIdentityLimitsSpanWindowsAndPrincipals() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a", reserved: 100))
  try await store.finalize(attempt: "a", evidence: nil)
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(admission("b", principal: "other", window: "next", reserved: 1))
  }
  try await store.finalize(attempt: "a", evidence: usage(amount: 0))
  try await store.admit(admission("b", principal: "other", window: "next", reserved: 1))
  await store.close()
}

@Test func compactedEvidenceStillAcceptsFinalAndLateTruth() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("a"))
  for revision in 1...128 {
    try await store.finalize(
      attempt: "a",
      evidence: usage(revision: Int64(revision), amount: Int64(revision), complete: false))
  }
  try await store.finalize(attempt: "a", evidence: usage(revision: 129, amount: 129))
  try await store.finalize(attempt: "a", evidence: usage(revision: 130, amount: 150))
  #expect(try await store.snapshot(attempt: "a").state == .settled)
  #expect(try await store.snapshot(attempt: "a").usage?.estimatedMicros == 150)
  try await store.finalize(attempt: "a", evidence: usage(revision: 130, amount: 150))
  await #expect(throws: ExecutionError.staleEvidence) {
    try await store.finalize(attempt: "a", evidence: usage(revision: 1, amount: 1, complete: false))
  }
  await #expect(throws: ExecutionError.conflict) {
    try await store.finalize(attempt: "a", evidence: usage(revision: 130, amount: 151))
  }
  await store.close()
  let recovered = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await recovered.snapshot(attempt: "a").usage?.estimatedMicros == 150)
  await #expect(throws: ExecutionError.staleEvidence) {
    try await recovered.finalize(
      attempt: "a", evidence: usage(revision: 1, amount: 1, complete: false))
  }
  await recovered.close()
  var db: OpaquePointer?
  #expect(sqlite3_open(path, &db) == SQLITE_OK)
  defer { sqlite3_close(db) }
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(db, "SELECT COUNT(*), MIN(revision) FROM evidence", -1, &statement, nil)
      == SQLITE_OK)
  defer { sqlite3_finalize(statement) }
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(sqlite3_column_int64(statement, 0) == 128)
  #expect(sqlite3_column_int64(statement, 1) == 3)
}

@Test(arguments: ["legacy", "sqlitex"])
func rejectedLegacySchemaDoesNotMutateDatabaseContentsOrJournal(_ table: String) async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  try rawSQL(
    path,
    "PRAGMA journal_mode=DELETE; CREATE TABLE \(table)(id INTEGER); INSERT INTO \(table) VALUES(42)"
  )
  let original = try Data(contentsOf: URL(fileURLWithPath: path))
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
  #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
}
