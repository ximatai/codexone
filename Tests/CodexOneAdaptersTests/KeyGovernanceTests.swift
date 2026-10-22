import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func keyPolicy(active: Int64 = 2, requests: Int64 = 20, unresolved: Int64 = 3) throws
  -> KeyPolicy
{
  try .init(
    models: ["synthetic-text"],
    limits: .init(
      requests: requests, active: active, unresolved: unresolved,
      budgetMicros: 100, unresolvedMicros: 100))
}
private func keyAdmission(
  _ id: String, key: ManagedKey, principal: String? = nil, window: String = "w"
) -> ExecutionAdmission {
  .init(
    attempt: id,
    owner: .init(
      principal: principal ?? key.principal, key: key.id, namespace: "synthetic", identity: "i"),
    window: window, policyVersion: "policy", pricingVersion: "price", reservedMicros: 10,
    keyRevision: key.revision, model: "synthetic-text")
}

@Test func keyRevisionsRevokeStaleAdmissionAndKeepPrincipalImmutable() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let secret = generateKeySecret()
  let key = try await store.createKey(
    id: "k", principal: "p", digest: keyDigest(secret), policy: keyPolicy())
  #expect(try await store.authenticateKey(digest: keyDigest(secret)) == key)
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.admit(keyAdmission("foreign", key: key, principal: "other"))
  }
  let winners = await withTaskGroup(of: Bool.self) { tasks in
    for _ in 0..<8 {
      tasks.addTask {
        do {
          _ = try await store.updateKey(
            id: key.id, revision: key.revision, enabled: false, policy: key.policy)
          return true
        } catch { return false }
      }
    }
    var result = 0
    for await won in tasks { if won { result += 1 } }
    return result
  }
  #expect(winners == 1)
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.authenticateKey(digest: keyDigest(secret))
  }
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.admit(keyAdmission("stale", key: key))
  }
  #expect(try await store.listKeys(after: nil).first?.principal == "p")
  await store.close()
}

@Test func perKeyLimitsAreAtomicAndUnknownExposureSurvivesWindowAndRestart() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let key = try await store.createKey(
    id: "k", principal: "p", digest: keyDigest("synthetic-governance-token"),
    policy: keyPolicy(unresolved: 2))
  let winners = await withTaskGroup(of: Bool.self) { tasks in
    for index in 0..<12 {
      tasks.addTask {
        do {
          try await store.admit(keyAdmission("a\(index)", key: key))
          return true
        } catch { return false }
      }
    }
    var count = 0
    for await won in tasks { if won { count += 1 } }
    return count
  }
  #expect(winners == 2)
  let other = try await store.createKey(
    id: "other", principal: "p", digest: keyDigest("synthetic-other-token"), policy: keyPolicy())
  try await store.admit(keyAdmission("other", key: other))
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await #expect(throws: ExecutionError.denied) {
    try await reopened.admit(keyAdmission("new-window", key: key, window: "new-window"))
  }
  #expect(try await reopened.snapshot(attempt: "other").state == .unknown)
  await reopened.close()
}

@Test func rotationDisablesOldKeyAtomicallyAndCannotEraseBindings() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let key = try await store.createKey(
    id: "k", principal: "p", digest: keyDigest("synthetic-old-token"),
    policy: keyPolicy(requests: 1))
  try await store.admit(keyAdmission("a", key: key))
  try await store.bind(attempt: "a", object: .init(type: "response", rawID: "r"))
  let rotated = try await store.rotateKey(
    id: "k", revision: 1, digest: keyDigest("synthetic-new-token"))
  #expect(
    rotated.id == key.id && rotated.principal == key.principal && rotated.policy == key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.authenticateKey(digest: keyDigest("synthetic-old-token"))
  }
  await #expect(throws: ExecutionError.conflict) {
    try await store.rotateKey(
      id: "k", revision: 1, digest: keyDigest("synthetic-conflict-token"))
  }
  #expect(
    try await store.resolve(
      principal: rotated.principal, object: .init(type: "response", rawID: "r")
    ).key == "k")
  try await store.finalize(attempt: "a", evidence: usage())
  #expect(try await store.snapshot(attempt: "a").state == .settled)
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(keyAdmission("after-rotation", key: rotated))
  }
  await store.close()
}

@Test func keyAuditFailureRollsBackRotationAndCapacityDoesNotDeleteHistory() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let digest = keyDigest("synthetic-governance-token")
  let key = try await store.createKey(id: "k", principal: "p", digest: digest, policy: keyPolicy())
  try rawSQL(
    path,
    "CREATE TRIGGER fail_audit BEFORE INSERT ON key_events BEGIN SELECT RAISE(ABORT,'synthetic'); END"
  )
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.rotateKey(
      id: "k", revision: 1, digest: keyDigest("synthetic-new-token"))
  }
  #expect(try await store.authenticateKey(digest: digest) == key)
  #expect(try await store.listKeys(after: nil).count == 1)
  try rawSQL(
    path,
    "DROP TRIGGER fail_audit; WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4095) INSERT INTO key_events SELECT 'audit-'||i,'k',1,'synthetic',1,'{}' FROM n"
  )
  await #expect(throws: ExecutionError.capacity) {
    try await store.updateKey(id: "k", revision: 1, enabled: true, policy: key.policy)
  }
  #expect(try await store.authenticateKey(digest: digest).revision == 1)
  let disabled = try await store.updateKey(id: "k", revision: 1, enabled: false, policy: key.policy)
  #expect(!disabled.enabled)
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.authenticateKey(digest: digest)
  }
  await #expect(throws: ExecutionError.capacity) {
    try await store.updateKey(id: "k", revision: 2, enabled: false, policy: key.policy)
  }
  await store.close()
}

@Test func explicitV1MigrationPreservesIntentBindingsAndPrivateConsistentBackup() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await store.admit(admission("old"))
  try await store.bind(attempt: "old", object: .init(type: "response", rawID: "r"))
  await #expect(throws: ExecutionError.instanceLocked) {
    try await SQLiteExecutionStore.migrate(path: path)
  }
  await store.close()
  try rawSQL(
    path,
    "DROP TABLE account_events; DROP TABLE accounts; DROP TABLE key_events; DROP TABLE managed_keys; DROP INDEX attempts_key; PRAGMA user_version=1"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  try await SQLiteExecutionStore.migrate(path: path)
  let backups = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.contains(".pre-v4-")
  }
  #expect(backups.count == 1)
  let backup = directory + "/" + backups[0]
  let attributes = try FileManager.default.attributesOfItem(atPath: backup)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  var db: OpaquePointer?
  #expect(sqlite3_open(backup, &db) == SQLITE_OK)
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(db, "SELECT state FROM attempts WHERE id='old'", -1, &statement, nil)
      == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(String(cString: sqlite3_column_text(statement, 0)) == "intent")
  sqlite3_finalize(statement)
  sqlite3_close(db)
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.snapshot(attempt: "old").state == .unknown)
  #expect(
    try await reopened.resolve(principal: "p", object: .init(type: "response", rawID: "r")).key
      == "key")
  await reopened.close()
}

@Test func failedV1UpgradeRollsBackAllNewTablesAndKeepsSourceVersion() async throws {
  let path = try temporaryExecutionPath()
  let directory = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await store.close()
  try rawSQL(
    path,
    "DROP TABLE account_events; DROP TABLE accounts; DROP TABLE key_events; DROP TABLE managed_keys; PRAGMA user_version=1"
  )
  // An index name conflict occurs after both CREATE TABLE statements, inside the migration transaction.
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteExecutionStore.migrate(path: path)
  }
  var db: OpaquePointer?
  #expect(sqlite3_open(path, &db) == SQLITE_OK)
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(
      db, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('managed_keys','key_events')", -1,
      &statement, nil) == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 0)
  sqlite3_finalize(statement)
  #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 1)
  sqlite3_finalize(statement)
  sqlite3_close(db)
  try rawSQL(path, "DROP INDEX attempts_key")
  try await SQLiteExecutionStore.migrate(path: path)
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await reopened.close()
}

@Test func keyLimitsChangePolicyVersionWithoutChangingProviderScopeOrPrices() throws {
  let config = try JSONDecoder().decode(
    SingleIdentityConfiguration.self,
    from: Data(
      #"{"managedKeys":true,"namespace":"synthetic","identity":"i","models":[{"id":"synthetic-text","inputMicrosPerMillion":0,"outputMicrosPerMillion":0}],"upstreamBaseURL":"http://127.0.0.1:9/v1","reservedMicros":1}"#
        .utf8))
  try config.validate()
  let first = ManagedKey(
    id: "k", principal: "p", revision: 1, enabled: true, policy: try keyPolicy(requests: 1),
    createdAtUnixSeconds: 1)
  let second = ManagedKey(
    id: "k2", principal: "p", revision: 1, enabled: true, policy: try keyPolicy(requests: 2),
    createdAtUnixSeconds: 1)
  let a = try config.makePolicy(token: nil, key: first)
  let b = try config.makePolicy(token: nil, key: second)
  #expect(a.policyVersion != b.policyVersion)
  #expect(a.pricingVersion == b.pricingVersion && a.owner.namespace == b.owner.namespace)
}

@Test func fullOrdinaryAuditStillAllowsEveryExistingKeyToBeRevoked() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let policy = try keyPolicy()
  for index in 0..<256 {
    _ = try await store.createKey(
      id: "k\(index)", principal: "p",
      digest: keyDigest("synthetic-public-revocation-token-\(index)"), policy: policy)
  }
  try rawSQL(
    path,
    "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<3840) INSERT INTO key_events SELECT 'audit-'||i,'k0',1,'synthetic',1,'{}' FROM n"
  )
  await #expect(throws: ExecutionError.capacity) {
    try await store.rotateKey(id: "k0", revision: 1, digest: keyDigest("synthetic-rotated-token"))
  }
  for index in 0..<256 {
    let key = try await store.updateKey(
      id: "k\(index)", revision: 1, enabled: false, policy: policy)
    #expect(!key.enabled && key.revision == 2)
  }
  await #expect(throws: ExecutionError.capacity) {
    try await store.updateKey(id: "k0", revision: 2, enabled: true, policy: policy)
  }
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.authenticateKey(digest: keyDigest("synthetic-public-revocation-token-255"))
  }
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.listKeys(after: nil).allSatisfy { !$0.enabled })
  await reopened.close()
}
