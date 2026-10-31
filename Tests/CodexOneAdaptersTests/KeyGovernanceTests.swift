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
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.updateKey(id: "k", revision: 1, enabled: true, policy: key.policy)
  }
  await store.close()
  try rawSQL(
    path,
    "DROP TRIGGER fail_audit; WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4095) INSERT INTO key_events SELECT 'audit-'||i,'k',1,'synthetic',1,'{}' FROM n"
  )
  let recovered = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await #expect(throws: ExecutionError.capacity) {
    try await recovered.updateKey(id: "k", revision: 1, enabled: true, policy: key.policy)
  }
  #expect(try await recovered.authenticateKey(digest: digest).revision == 1)
  let disabled = try await recovered.updateKey(
    id: "k", revision: 1, enabled: false, policy: key.policy)
  #expect(!disabled.enabled)
  await #expect(throws: ExecutionError.unauthorized) {
    try await recovered.authenticateKey(digest: digest)
  }
  await #expect(throws: ExecutionError.capacity) {
    try await recovered.updateKey(id: "k", revision: 2, enabled: false, policy: key.policy)
  }
  await recovered.close()
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
    removeObservationSchema
      + "DROP TABLE account_events; DROP TABLE accounts; DROP TABLE key_events; DROP TABLE managed_keys; DROP INDEX attempts_key; DROP TABLE maintenance_events; DROP TABLE maintenance_state; PRAGMA user_version=1"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  try await SQLiteExecutionStore.migrate(path: path)
  let backups = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.contains(".pre-v9-")
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
    removeObservationSchema
      + "DROP TABLE account_events; DROP TABLE accounts; DROP TABLE key_events; DROP TABLE managed_keys; DROP TABLE maintenance_events; DROP TABLE maintenance_state; PRAGMA user_version=1"
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
    id: "k2", principal: "p", revision: 1, enabled: true,
    policy: try decodedKeyPolicy([
      "requests": NSNull(), "active": 2, "unresolved": 3,
      "budgetMicros": 100, "unresolvedMicros": 100,
    ]),
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

private let limitNames = ["requests", "active", "unresolved", "budgetMicros", "unresolvedMicros"]
private func decodedKeyPolicy(_ limits: [String: Any]) throws -> KeyPolicy {
  try JSONDecoder().decode(
    KeyPolicy.self,
    from: JSONSerialization.data(withJSONObject: [
      "models": ["synthetic-text"], "limits": limits,
    ]))
}

@Test func nullableKeyDimensionsSkipOnlyTheirOwnAdmissionCheck() async throws {
  for unlimited in limitNames {
    // First prove the numeric dimension refuses, then switch only it to null.
    // Pair it with every other bounded dimension to prove those still refuse.
    for bounded in [unlimited] + limitNames.filter({ $0 != unlimited }) {
      let path = try temporaryExecutionPath()
      let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
      var limits = Dictionary(uniqueKeysWithValues: limitNames.map { ($0, 100 as Any) })
      limits[bounded] = bounded.contains("Micros") ? 10 : 1
      var key = try await store.createKey(
        id: "k", principal: "p",
        digest: keyDigest("synthetic-null-limit"), policy: decodedKeyPolicy(limits))
      try await store.admit(keyAdmission("first", key: key))
      await #expect(throws: ExecutionError.denied) {
        try await store.admit(keyAdmission("bounded", key: key))
      }
      limits[unlimited] = NSNull()
      key = try await store.updateKey(
        id: key.id, revision: key.revision, enabled: true,
        policy: decodedKeyPolicy(limits))
      if bounded == unlimited {
        try await store.admit(keyAdmission("unlimited", key: key))
      } else {
        await #expect(throws: ExecutionError.denied) {
          try await store.admit(keyAdmission("still-bounded", key: key))
        }
      }
      await store.close()
      try FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
  }
}

@Test func fullyUnlimitedKeyKeepsLedgerAndGlobalRequestLimit() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path,
    limits: .init(requests: 105, active: 4, unresolved: 4, budgetMicros: 100))
  let policy = try decodedKeyPolicy(
    Dictionary(uniqueKeysWithValues: limitNames.map { ($0, NSNull()) }))
  let key = try await store.createKey(
    id: "k", principal: "p",
    digest: keyDigest("synthetic-null-limit"), policy: policy)
  for index in 0..<105 {
    let attempt = "a\(index)"
    try await store.admit(keyAdmission(attempt, key: key))
    try await store.finalize(
      attempt: attempt,
      evidence: .init(
        revision: 1, inputTokens: 0,
        outputTokens: 0, cachedTokens: 0, images: 0, estimatedMicros: 0, completeness: .complete))
  }
  await #expect(throws: ExecutionError.denied) {
    try await store.admit(keyAdmission("global-denied", key: key))
  }
  #expect(try await store.snapshot(attempt: "a104").state == .settled)
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path,
    limits: .init(requests: 105, active: 4, unresolved: 4, budgetMicros: 100))
  #expect(try await reopened.listKeys(after: nil).first?.policy == policy)
  await reopened.close()
}

@Test func nullableLimitsRequireEveryFieldAndRejectInvalidNumericValues() throws {
  let valid = Dictionary(uniqueKeysWithValues: limitNames.map { ($0, NSNull() as Any) })
  let policy = try decodedKeyPolicy(valid)
  let encoded = try JSONEncoder().encode(policy)
  #expect(try JSONDecoder().decode(KeyPolicy.self, from: encoded) == policy)
  let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect((object["limits"] as? [String: Any])?.count == 5)
  for field in limitNames {
    var missing = valid
    missing.removeValue(forKey: field)
    #expect(throws: (any Error).self) { try decodedKeyPolicy(missing) }
    for invalid: Any in [-1, 0, 1_000_000_000_001, "invalid", true] {
      var bad = valid
      bad[field] = invalid
      #expect(throws: (any Error).self) { try decodedKeyPolicy(bad) }
    }
  }
}

@Test func round2KeyExpirationRejectsBeforeAdmissionAndPreservesDispatchedWork() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let digest = String(repeating: "a", count: 64)
  let key = try await store.createKey(
    id: "expiry", principal: "expiry", digest: digest,
    policy: .init(models: ["synthetic-text"], limits: syntheticLimits))
  let now = Int64(Date().timeIntervalSince1970)
  for revision in [Int64(0), -1, 1_000_001] {
    await #expect(throws: ExecutionError.invalidCommand) {
      try await store.setKeyExpiration(id: key.id, revision: revision, expiresAtUnixSeconds: nil)
    }
  }
  let future = try await store.setKeyExpiration(
    id: key.id, revision: key.revision, expiresAtUnixSeconds: now + 3600)
  #expect(
    try await store.authenticateKey(digest: digest).expiresAtUnixSeconds
      == future.expiresAtUnixSeconds)
  func command(_ id: String, revision: Int64) -> ExecutionAdmission {
    .init(
      attempt: id,
      owner: .init(principal: "expiry", key: "expiry", namespace: "synthetic", identity: "single"),
      window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1,
      keyRevision: revision, model: "synthetic-text")
  }
  try await store.admit(command("dispatched", revision: future.revision))
  let expired = try await store.setKeyExpiration(
    id: key.id, revision: future.revision, expiresAtUnixSeconds: now)
  await #expect(throws: ExecutionError.keyExpired) {
    try await store.authenticateKey(digest: digest)
  }
  await #expect(throws: ExecutionError.keyExpired) {
    try await store.admit(command("denied", revision: expired.revision))
  }
  await #expect(throws: ExecutionError.keyExpired) {
    try await store.admit(command("stale-expired", revision: future.revision))
  }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await store.snapshot(attempt: "denied")
  }
  #expect(protocolFailure(ExecutionError.keyExpired).status == 401)
  #expect(protocolFailure(ExecutionError.keyExpired).code == "api_key_expired")
  try await store.finalize(attempt: "dispatched", evidence: usage(amount: 1))
  #expect(try await store.snapshot(attempt: "dispatched").state == .settled)
  let extended = try await store.setKeyExpiration(
    id: key.id, revision: expired.revision, expiresAtUnixSeconds: now + 7200)
  #expect(try await store.authenticateKey(digest: digest).revision == extended.revision)
  let cleared = try await store.setKeyExpiration(
    id: key.id, revision: extended.revision, expiresAtUnixSeconds: nil)
  #expect(cleared.expiresAtUnixSeconds == nil)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await store.setKeyExpiration(
      id: key.id, revision: cleared.revision, expiresAtUnixSeconds: 0)
  }
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(try await reopened.authenticateKey(digest: digest).expiresAtUnixSeconds == nil)
  await reopened.close()
}

@Test func keyDisplayNameValidationCASPreservationAndAuthenticationIsolation() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let digest = keyDigest("synthetic-name-token")
  var key = try await store.createKey(
    id: "named", principal: "owner", digest: digest, policy: keyPolicy())
  // Legacy metadata omits the optional field entirely.
  try rawSQL(
    path, "UPDATE managed_keys SET metadata_json=json_remove(metadata_json,'$.displayName')")
  #expect(try await store.listKeys(after: nil).first?.displayName == nil)
  for invalid in [
    "", String(repeating: "a", count: 65), String(repeating: "😀", count: 65), "a\n", "a\u{200D}",
    "a\u{2028}", "a\u{2029}", "a\u{0000}", "a\u{FFFF}",
  ] {
    await #expect(throws: ExecutionError.invalidCommand) {
      try await store.setKeyDisplayName(id: key.id, revision: key.revision, displayName: invalid)
    }
  }
  let name = String(repeating: "😀", count: 64)
  key = try await store.setKeyDisplayName(id: key.id, revision: key.revision, displayName: name)
  #expect(key.displayName == name)
  await #expect(throws: ExecutionError.conflict) {
    try await store.setKeyDisplayName(id: key.id, revision: 1, displayName: "stale")
  }
  let second = try await store.createKey(
    id: "other-name", principal: "other-owner",
    digest: keyDigest("synthetic-other-name-token"), policy: keyPolicy())
  _ = try await store.setKeyDisplayName(id: second.id, revision: second.revision, displayName: name)
  #expect(try await store.authenticateKey(digest: digest).principal == "owner")
  #expect(
    try await store.authenticateKey(digest: keyDigest("synthetic-other-name-token")).principal
      == "other-owner")
  await #expect(throws: ExecutionError.unauthorized) {
    try await store.authenticateKey(digest: keyDigest(name))
  }
  key = try await store.updateKey(
    id: key.id, revision: key.revision, enabled: true, policy: key.policy)
  #expect(key.displayName == name)
  key = try await store.setKeyExpiration(
    id: key.id, revision: key.revision, expiresAtUnixSeconds: nil)
  #expect(key.displayName == name)
  key = try await store.rotateKey(
    id: key.id, revision: key.revision, digest: keyDigest("synthetic-rotated-name-token"))
  #expect(key.displayName == name)
  try await store.admit(keyAdmission("named-request", key: key))
  let reader = try await store.makeUsageReader()
  #expect(try await reader.usageOptions().keyOptions.first { $0.id == key.id }?.displayName == name)
  #expect(try await reader.keyUsage().keys.first { $0.key.id == key.id }?.key.displayName == name)
  #expect(try await reader.inFlightUsage(limit: 10).first?.displayName == name)
  let hour = Int64(Date().timeIntervalSince1970) / 3600 * 3600
  let report = try await reader.queryUsage(
    .init(startUnixSeconds: hour, endUnixSeconds: hour + 3600))
  #expect(report.rows.first?.displayName == name)
  key = try await store.setKeyDisplayName(id: key.id, revision: key.revision, displayName: nil)
  #expect(key.displayName == nil)
  #expect(try await reader.inFlightUsage(limit: 10).first?.displayName == nil)
  #expect(try await reader.usageOptions().keyOptions.first { $0.id == key.id }?.displayName == nil)
  await reader.close()
  await store.close()
}
