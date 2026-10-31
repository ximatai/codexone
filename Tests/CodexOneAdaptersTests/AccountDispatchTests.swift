import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private struct DispatchFixture {
  let path: String
  let store: SQLiteExecutionStore
  let app: AccountCredentials
  let account: ManagedAccount
  static func make(mode: AccountMode = .enabled, expires: Int64 = 2_000_000_000) async throws
    -> Self
  {
    let path = try temporaryExecutionPath()
    let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
    let app = AccountCredentials(
      store: store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "7c", count: 32)))
    var account = try await app.importVerified(
      id: "managed-account", namespace: "synthetic/managed-account",
      credential: AccountCredential(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
        expiresAtUnixSeconds: expires))
    if mode != .disabled {
      account = try await store.setAccountMode(
        id: account.id, revision: account.revision, mode: mode)
    }
    return Self(path: path, store: store, app: app, account: account)
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}
private func dispatchAdmission(
  _ id: String, work: AccountDispatchWork, snapshot: AccountDispatchSnapshot? = nil,
  keyRevision: Int64? = nil
) -> ExecutionAdmission {
  .init(
    attempt: id,
    owner: .init(
      principal: "p", key: "key", namespace: work.account.namespace, identity: work.account.id),
    window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1,
    keyRevision: keyRevision, model: "synthetic-text", accountSnapshot: snapshot ?? work.snapshot)
}

@Test func preparedDispatchCannotSurviveDisableRefreshReauthorizationOrExpiry() async throws {
  for change in ["disable", "refresh", "reauthorize", "expiry"] {
    let f = try await DispatchFixture.make(
      expires: change == "expiry" ? Int64(Date().timeIntervalSince1970) + 2 : 2_000_000_000)
    let preparation = AccountCredentials(
      store: f.store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "7c", count: 32)),
      now: { Int64(Date().timeIntervalSince1970) - 301 })
    let work = try await preparation.prepareDispatch(id: f.account.id, continuation: false)
    let snapshot = work.snapshot
    switch change {
    case "disable":
      _ = try await f.store.setAccountMode(
        id: f.account.id, revision: f.account.revision, mode: .disabled)
    case "refresh":
      _ = try await f.app.beginRefresh(id: f.account.id, revision: f.account.revision)
    case "reauthorize":
      _ = try await f.app.reauthorizeVerified(
        id: f.account.id, revision: f.account.revision, namespace: f.account.namespace,
        credential: AccountCredential(
          accessToken: "synthetic-new-access", refreshToken: "synthetic-new-refresh", idToken: nil,
          expiresAtUnixSeconds: 2_000_000_000))
    default:
      try await Task.sleep(for: .milliseconds(2100))
    }
    await #expect(throws: change == "expiry" ? ExecutionError.denied : ExecutionError.conflict) {
      try await f.store.admit(dispatchAdmission("stale", work: work, snapshot: snapshot))
    }
    await #expect(throws: ExecutionError.unknownAttempt) {
      try await f.store.snapshot(attempt: "stale")
    }
    await f.close()
  }
}

@Test func managedDispatchRequiresSnapshotReadyModeAffinityAndCurrentAccess() async throws {
  for mode: AccountMode in [.enabled, .draining, .disabled] {
    let f = try await DispatchFixture.make(mode: mode)
    if mode != .enabled {
      await #expect(throws: AccountDispatchError.unavailable) {
        try await f.app.prepareDispatch(id: f.account.id, continuation: false)
      }
    }
    if mode == .disabled {
      await #expect(throws: AccountDispatchError.unavailable) {
        try await f.app.prepareDispatch(id: f.account.id, continuation: true)
      }
    } else {
      let work = try await f.app.prepareDispatch(id: f.account.id, continuation: mode == .draining)
      #expect(String(reflecting: work) == "AccountDispatchWork(redacted)")
      let valid = dispatchAdmission("valid", work: work)
      let unguarded = ExecutionAdmission(
        attempt: "unguarded", owner: valid.owner, window: "w", policyVersion: "1",
        pricingVersion: "1",
        reservedMicros: 1)
      await #expect(throws: ExecutionError.invalidCommand) { try await f.store.admit(unguarded) }
      if mode == .draining {
        let unbound = try AccountDispatchSnapshot(
          revision: work.snapshot.revision, credentialVersion: work.snapshot.credentialVersion,
          accessExpiresAtUnixSeconds: work.snapshot.accessExpiresAtUnixSeconds, continuation: false)
        await #expect(throws: ExecutionError.denied) {
          try await f.store.admit(dispatchAdmission("unbound", work: work, snapshot: unbound))
        }
      }
      try await f.store.admit(valid)
      let persisted = try await f.store.snapshot(attempt: "valid")
      #expect(persisted.admission.accountSnapshot == work.snapshot)
      let bytes = try JSONEncoder().encode(persisted)
      #expect(!bytes.contains(Data(work.credential.accessToken.utf8)))
      #expect(!bytes.contains(Data(work.credential.refreshToken.utf8)))
    }
    await f.close()
  }
  let expired = try await DispatchFixture.make(expires: 1)
  await #expect(throws: AccountDispatchError.refreshRequired) {
    try await expired.app.prepareDispatch(id: expired.account.id, continuation: false)
  }
  #expect(try await expired.store.listAccounts().first?.authorization == .ready)
  await expired.close()
}

@Test func managedAccountAndKeySnapshotsAreCheckedInOneAdmissionTransaction() async throws {
  let f = try await DispatchFixture.make()
  let key = try await f.store.createKey(
    id: "key", principal: "p", digest: String(repeating: "a", count: 64),
    policy: KeyPolicy(models: ["synthetic-text"], limits: syntheticLimits))
  let work = try await f.app.prepareDispatch(id: f.account.id, continuation: false)
  let disabled = try await f.store.updateKey(
    id: key.id, revision: key.revision, enabled: false, policy: key.policy)
  await #expect(throws: ExecutionError.unauthorized) {
    try await f.store.admit(dispatchAdmission("revoked-key", work: work, keyRevision: key.revision))
  }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await f.store.snapshot(attempt: "revoked-key")
  }
  let enabled = try await f.store.updateKey(
    id: disabled.id, revision: disabled.revision, enabled: true, policy: disabled.policy)
  try await f.store.admit(dispatchAdmission("current", work: work, keyRevision: enabled.revision))
  #expect(try await f.store.snapshot(attempt: "current").admission.accountSnapshot == work.snapshot)
  _ = try await f.store.setAccountMode(
    id: f.account.id, revision: f.account.revision, mode: .disabled)
  // Ordinary disable prevents new work, but cannot erase responsibility for an admitted execution.
  try await f.store.bind(
    attempt: "current", object: .init(type: "response", rawID: "synthetic-response"))
  try await f.store.finalize(
    attempt: "current",
    evidence: .init(
      revision: 1, inputTokens: 1, outputTokens: 1, cachedTokens: 0, images: 0,
      estimatedMicros: 1, completeness: .complete))
  #expect(try await f.store.snapshot(attempt: "current").state == .settled)

  await f.close()
}

@Test(arguments: [3, 4, 5, 6, 7, 8])
func legacyExplicitMigrationBacksUpPendingTruthBeforeV9StartupRecovery(version: Int) async throws {
  let f = try await DispatchFixture.make()
  try await f.store.admit(admission("historical"))
  _ = try await f.app.beginRefresh(id: f.account.id, revision: f.account.revision)
  await f.store.close()
  try rawSQL(
    f.path,
    "ALTER TABLE accounts DROP COLUMN display_name; "
      + (version < 5 ? removeObservationSchema : "DROP INDEX attempts_in_flight; ")
      + (version < 7 ? "DROP TABLE maintenance_events; DROP TABLE maintenance_state; " : "")
      + "PRAGMA user_version=\(version)"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: f.path, limits: syntheticLimits)
  }
  try await SQLiteExecutionStore.migrate(path: f.path)
  let directory = (f.path as NSString).deletingLastPathComponent
  let backups = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.contains(".pre-v9-") && $0.hasSuffix(".sqlite")
  }
  #expect(backups.count == 1)
  var db: OpaquePointer?
  #expect(sqlite3_open(directory + "/" + backups[0], &db) == SQLITE_OK)
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(
      db,
      "SELECT (SELECT user_version FROM pragma_user_version), (SELECT state FROM attempts WHERE id='historical'), (SELECT authorization FROM accounts WHERE id='managed-account')",
      -1, &statement, nil) == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(sqlite3_column_int64(statement, 0) == version)
  #expect(String(cString: sqlite3_column_text(statement, 1)) == "intent")
  #expect(String(cString: sqlite3_column_text(statement, 2)) == "refreshing")
  sqlite3_finalize(statement)
  sqlite3_close(db)
  let reopened = try await SQLiteExecutionStore.open(path: f.path, limits: syntheticLimits)
  #expect(try await reopened.snapshot(attempt: "historical").state == .unknown)
  #expect(try await reopened.snapshot(attempt: "historical").admission.accountSnapshot == nil)
  #expect(
    try await reopened.accountCredential(id: f.account.id).account.authorization == .authUncertain)
  await reopened.close()
  try await SQLiteExecutionStore.migrate(path: f.path)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory).filter {
      $0.contains(".pre-v9-") && $0.hasSuffix(".sqlite")
    }.count == 1)
  await f.close()
}

@Test func maximumManagedNamespaceCanAdmitBindAndResolveWithoutWideningOtherIDs() async throws {
  let f = try await DispatchFixture.make()
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "7c", count: 32))
  let app = AccountCredentials(store: f.store, protection: cipher)
  let namespace = "synthetic/" + String(repeating: "n", count: 502)
  #expect(namespace.utf8.count == 512)
  let account = try await app.importVerified(
    id: "long-namespace", namespace: namespace,
    credential: AccountCredential(
      accessToken: "synthetic-long-access", refreshToken: "synthetic-long-refresh", idToken: nil,
      expiresAtUnixSeconds: 2_000_000_000))
  _ = try await f.store.setAccountMode(id: account.id, revision: account.revision, mode: .enabled)
  let work = try await app.prepareDispatch(id: account.id, continuation: false)
  try await f.store.admit(dispatchAdmission("long", work: work))
  let object = ObjectBinding(type: "response", rawID: "synthetic-long-response")
  try await f.store.bind(attempt: "long", object: object)
  #expect(
    try await f.store.resolve(principal: "p", object: object, namespace: namespace).identity
      == account.id)
  await #expect(throws: ExecutionError.unknownObject) {
    try await f.store.resolve(principal: "other", object: object, namespace: namespace)
  }
  let invalid = ExecutionAdmission(
    attempt: String(repeating: "a", count: 257),
    owner: .init(principal: "p", key: "key", namespace: namespace, identity: account.id),
    window: "w", policyVersion: "1", pricingVersion: "1", reservedMicros: 1,
    accountSnapshot: work.snapshot)
  await #expect(throws: ExecutionError.invalidCommand) { try await f.store.admit(invalid) }
  await f.close()
}

@Test func dispatchWindowDoesNotShortenObservationValidity() async throws {
  let f = try await DispatchFixture.make(expires: 2_000_000_000)
  for remaining: Int64 in [901, 900, 301, 300, 1, 0] {
    let app = AccountCredentials(
      store: f.store,
      protection: try AccountCredentialCipher(hexKey: String(repeating: "7c", count: 32)),
      now: { 2_000_000_000 - remaining })
    if remaining > 300 {
      #expect(
        try await app.prepareDispatch(id: f.account.id, continuation: false).account.id
          == f.account.id)
    } else {
      await #expect(throws: AccountDispatchError.refreshRequired) {
        try await app.prepareDispatch(id: f.account.id, continuation: false)
      }
    }
    if remaining > 0 {
      #expect(try await app.prepareObservation(id: f.account.id).account.id == f.account.id)
      #expect(
        try await app.needsProactiveRefresh(id: f.account.id, windowSeconds: 900)
          == (remaining <= 900))
    } else {
      await #expect(throws: QuotaObservationFailure.refreshRequired) {
        try await app.prepareObservation(id: f.account.id)
      }
    }
  }
  await f.close()
}
