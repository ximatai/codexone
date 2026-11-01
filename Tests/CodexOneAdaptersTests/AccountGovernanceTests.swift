import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func accountFixture(_ id: String = "account", version: Int64 = 1) throws -> (
  AccountCredentialCipher, AccountCredentialContext, String
) {
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let context = try AccountCredentialContext(
    identity: id, namespace: "synthetic/" + id, version: version)
  let credential = try AccountCredential(
    accessToken: "synthetic-access-" + String(version),
    refreshToken: "synthetic-refresh-" + String(version), idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  return (cipher, context, try cipher.seal(credential, context: context))
}
@Test func accountRefreshCASPreservesConcurrentDisableAndRejectsIdentityChange() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (_, context, envelope) = try accountFixture()
  let created = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  #expect(created.mode == .disabled && created.authorization == .ready)
  let enabled = try await store.setAccountMode(
    id: created.id, revision: created.revision, mode: .enabled)
  let pending = try await store.beginAccountRefresh(
    id: enabled.id, revision: enabled.revision, intent: "operation")
  await #expect(throws: ExecutionError.conflict) {
    try await store.beginAccountRefresh(
      id: enabled.id, revision: enabled.revision, intent: "duplicate")
  }
  let disabled = try await store.setAccountMode(
    id: enabled.id, revision: pending.account.revision, mode: .disabled)
  let (_, nextContext, nextEnvelope) = try accountFixture(version: 2)
  let finished = try await store.finishAccountRefresh(
    id: enabled.id, credentialVersion: 1, intent: "operation", envelope: nextEnvelope)
  #expect(
    finished.mode == .disabled && finished.authorization == .ready
      && finished.credentialVersion == 2)
  #expect(finished.revision == disabled.revision + 1 && finished.refreshIntent == nil)
  let stored = try await store.accountCredential(id: finished.id)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  #expect(
    try cipher.open(stored.envelope, context: nextContext).refreshToken == "synthetic-refresh-2")
  await #expect(throws: ExecutionError.conflict) {
    try await store.finishAccountRefresh(
      id: enabled.id, credentialVersion: 1, intent: "operation", envelope: nextEnvelope)
  }
  await #expect(throws: AccountAuthorizationFailure(.identityMismatch)) {
    try await store.replaceVerifiedAccountCredential(
      id: finished.id, revision: finished.revision, namespace: "synthetic/other",
      envelope: nextEnvelope)
  }
  let publicMetadata = try JSONEncoder().encode(await store.listAccounts())
  #expect(!String(decoding: publicMetadata, as: UTF8.self).contains("v1."))
  await store.close()
  let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
  #expect(!bytes.contains(Data("synthetic-refresh-2".utf8)))
}
@Test func failedRefreshCommitRollsBackCiphertextAndRestartNeverReadiesOldToken() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (_, context, envelope) = try accountFixture()
  let created = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  _ = try await store.beginAccountRefresh(
    id: created.id, revision: created.revision, intent: "operation")
  try rawSQL(
    path,
    "CREATE TRIGGER fail_refresh BEFORE INSERT ON account_events WHEN NEW.action='refresh_commit' BEGIN SELECT RAISE(ABORT,'synthetic'); END"
  )
  let (_, _, nextEnvelope) = try accountFixture(version: 2)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.finishAccountRefresh(
      id: created.id, credentialVersion: 1, intent: "operation", envelope: nextEnvelope)
  }
  let rolledBack = try await store.accountCredential(id: created.id)
  #expect(
    rolledBack.envelope == envelope && rolledBack.account.authorization == .refreshing
      && rolledBack.account.credentialVersion == 1)
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let uncertain = try await reopened.accountCredential(id: created.id)
  #expect(
    uncertain.account.authorization == .authUncertain
      && uncertain.account.refreshIntent == "operation")
  #expect(uncertain.envelope == envelope && uncertain.account.credentialVersion == 1)
  await #expect(throws: ExecutionError.conflict) {
    try await reopened.beginAccountRefresh(
      id: created.id, revision: uncertain.account.revision, intent: "retry")
  }
  await #expect(throws: ExecutionError.conflict) {
    try await reopened.finishAccountRefresh(
      id: created.id, credentialVersion: 1, intent: "operation", envelope: nextEnvelope)
  }
  let replacement = try await reopened.replaceVerifiedAccountCredential(
    id: created.id, revision: uncertain.account.revision, namespace: context.namespace,
    envelope: nextEnvelope)
  #expect(
    replacement.authorization == .ready && replacement.mode == .disabled
      && replacement.credentialVersion == 2)
  await reopened.close()
}
@Test func refreshCompletionAndAllAccountRevocationsHaveReservedAuditSpace() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  for index in 0..<64 {
    let id = "account-" + String(index)
    let (_, context, envelope) = try accountFixture("account-" + String(index))
    let created = try await store.createVerifiedAccount(
      id: id, namespace: context.namespace, envelope: envelope)
    let enabled = try await store.setAccountMode(id: id, revision: created.revision, mode: .enabled)
    _ = try await store.beginAccountRefresh(
      id: id, revision: enabled.revision, intent: "operation-" + String(index))
  }
  // Leave exactly one pre-reserved completion event per in-flight refresh at the ordinary boundary.
  try rawSQL(
    path,
    "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<3840) INSERT INTO account_events SELECT 'fill-'||x,'account-0',1,'synthetic','{}',1 FROM n"
  )
  for item in try await store.listAccounts() {
    _ = try await store.setAccountMode(id: item.id, revision: item.revision, mode: .disabled)
  }
  await #expect(throws: ExecutionError.capacity) {
    try await store.setAccountMode(id: "account-0", revision: 4, mode: .enabled)
  }
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let recovered = try await reopened.listAccounts()
  #expect(
    recovered.count == 64
      && recovered.allSatisfy { $0.authorization == .authUncertain && $0.mode == .disabled })
  await reopened.close()
}
@Test func v2MigrationPreservesKeysAndRejectsOrdinaryStartupUntilExplicitUpgrade() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let policy = try KeyPolicy(models: ["synthetic"], limits: syntheticLimits)
  let key = try await store.createKey(
    id: "key", principal: "p", digest: String(repeating: "a", count: 64), policy: policy)
  await store.close()
  try rawSQL(
    path,
    removeObservationSchema
      + "DROP TABLE account_events; DROP TABLE accounts; DROP TABLE maintenance_events; DROP TABLE maintenance_state; PRAGMA user_version=2"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: testClock)
  }
  // The second table fails after CREATE accounts; neither it nor the version may survive.
  try rawSQL(path, "CREATE TABLE account_events(id TEXT)")
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteExecutionStore.migrate(path: path, clock: testClock)
  }
  var db: OpaquePointer?
  #expect(sqlite3_open(path, &db) == SQLITE_OK)
  var statement: OpaquePointer?
  #expect(
    sqlite3_prepare_v2(
      db, "SELECT COUNT(*) FROM sqlite_master WHERE name='accounts'", -1, &statement, nil)
      == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 0)
  sqlite3_finalize(statement)
  #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 2)
  sqlite3_finalize(statement)
  sqlite3_close(db)
  try rawSQL(path, "DROP TABLE account_events")
  try await SQLiteExecutionStore.migrate(path: path, clock: testClock)
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  #expect(try await reopened.listKeys() == [key])
  #expect(try await reopened.listAccounts().isEmpty)
  await reopened.close()
}

@Test func accountUseCasesVerifyContextAndFailClosedAfterProviderIdentityChange() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  let credential = try AccountCredential(
    accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  let account = try await app.importVerified(
    id: "account", namespace: "synthetic/account", credential: credential)
  let wrongKey = try AccountCredentialCipher(hexKey: String(repeating: "3c", count: 32))
  let wrong = AccountCredentials(store: store, protection: wrongKey, clock: testClock)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await wrong.beginRefresh(id: account.id, revision: account.revision)
  }
  #expect(try await store.accountCredential(id: account.id).account == account)
  let work = try await app.beginRefresh(id: account.id, revision: account.revision)
  await #expect(throws: ExecutionError.conflict) {
    try await app.finishVerifiedRefresh(
      work, namespace: "synthetic/other-account", credential: credential)
  }
  let uncertain = try await store.accountCredential(id: account.id).account
  #expect(uncertain.authorization == .authUncertain && uncertain.credentialVersion == 1)
  let fresh = try await app.reauthorizeVerified(
    id: account.id, revision: uncertain.revision, namespace: account.namespace,
    credential: credential)
  #expect(fresh.authorization == .ready && fresh.credentialVersion == 2 && fresh.mode == .disabled)
  let maximum = try AccountCredential(
    accessToken: String(repeating: "/", count: 16_384),
    refreshToken: String(repeating: "/", count: 16_384), idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  let secondWork = try await app.beginRefresh(id: fresh.id, revision: fresh.revision)
  let finished = try await app.finishVerifiedRefresh(
    secondWork, namespace: account.namespace, credential: maximum)
  #expect(finished.authorization == .ready && finished.credentialVersion == 3)
  let stored = try await store.accountCredential(id: account.id)
  let context = try AccountCredentialContext(
    identity: account.id, namespace: account.namespace, version: 3)
  #expect(try cipher.open(stored.envelope, context: context).refreshToken == maximum.refreshToken)
  await store.close()
}

@Test func storageFailureStopsFurtherRefreshIntentsEvenIfDatabaseBecomesWritable() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  let credential = try AccountCredential(
    accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  let account = try await app.importVerified(
    id: "account", namespace: "synthetic/account", credential: credential)
  try rawSQL(
    path,
    "CREATE TRIGGER fail_account_write BEFORE INSERT ON account_events BEGIN SELECT RAISE(ABORT,'synthetic'); END"
  )
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.setAccountMode(id: account.id, revision: account.revision, mode: .enabled)
  }
  #expect(!store.isAvailable)
  try rawSQL(path, "DROP TRIGGER fail_account_write")
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await app.beginRefresh(id: account.id, revision: account.revision)
  }
  #expect(try await store.accountCredential(id: account.id).account == account)
  await store.close()
}

@Test func authoritativeRefreshRejectionPersistsRequiresAuthUntilVerifiedReauthorization()
  async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (cipher, context, envelope) = try accountFixture()
  let account = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  let work = try await app.beginRefresh(id: account.id, revision: account.revision)
  let rejected = try await app.failRefresh(work, authorizationRequired: true)
  #expect(rejected.authorization == .requiresAuth && rejected.credentialVersion == 1)
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  #expect(try await reopened.accountCredential(id: account.id).account == rejected)
  let nextApp = AccountCredentials(store: reopened, protection: cipher, clock: testClock)
  await #expect(throws: ExecutionError.conflict) {
    try await nextApp.beginRefresh(id: account.id, revision: rejected.revision)
  }
  let fresh = try cipher.open(envelope, context: context)
  let restored = try await nextApp.reauthorizeVerified(
    id: account.id, revision: rejected.revision, namespace: account.namespace, credential: fresh)
  #expect(
    restored.authorization == .ready && restored.credentialVersion == 2
      && restored.refreshIntent == nil)
  await reopened.close()
}

@Test func imageAndConversationCatalogCapacityPreservesAll48CooldownsAndUsageOptions() async throws
{
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (_, context, envelope) = try accountFixture()
  let account = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  let models = Set((0..<48).map { "synthetic-model-\($0)" })
  try await store.configureHealthModels(models)
  try await store.perform { db in
    for model in models {
      try db.write(
        "INSERT INTO account_model_health VALUES(?,?,?,?)",
        [
          .text(account.id), .text(model), .number(testUnixSeconds + 3600),
          .text("rate_limited"),
        ])
    }
  }
  do {
    let health = try await store.accountHealth(id: account.id)
    #expect(health.cooldowns.count == 48 && store.isAvailable)
    #expect(
      try await store.hasHealthyModel(
        id: account.id, credentialVersion: account.credentialVersion, models: models) == false)
    let reader = try await store.makeUsageReader()
    do { #expect(try await reader.usageOptions().models.count == 48) } catch {
      await reader.close()
      throw error
    }
    await reader.close()
  } catch {
    await store.close()
    throw error
  }
  await store.close()
}

@Test func round2AccountDisplayNameBoundariesCASAndRestart() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (_, context, envelope) = try accountFixture()
  let created = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  for name in ["", String(repeating: "a", count: 65), "bad\nname", "bad\u{202E}name"] {
    await #expect(throws: ExecutionError.invalidCommand) {
      try await store.setAccountDisplayName(
        id: created.id, revision: created.revision, displayName: name)
    }
  }
  for revision in [Int64(0), -1, 1_000_001] {
    await #expect(throws: ExecutionError.invalidCommand) {
      try await store.setAccountDisplayName(id: created.id, revision: revision, displayName: nil)
    }
  }
  let named = try await store.setAccountDisplayName(
    id: created.id, revision: 1, displayName: String(repeating: "名", count: 64))
  await #expect(throws: ExecutionError.conflict) {
    try await store.setAccountDisplayName(id: created.id, revision: 1, displayName: "stale")
  }
  let enabled = try await store.setAccountMode(
    id: named.id, revision: named.revision, mode: .enabled)
  #expect(enabled.displayName == named.displayName)
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  #expect(try await reopened.listAccounts().first?.displayName == named.displayName)
  let cleared = try await reopened.setAccountDisplayName(
    id: named.id, revision: enabled.revision, displayName: nil)
  #expect(cleared.displayName == nil)
  await reopened.close()
}

@Test func round2DisplayNameCannotConsumeReservedRefreshCompletionRevision() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let (_, context, envelope) = try accountFixture()
  _ = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace, envelope: envelope)
  try await store.perform { db in
    try db.write(
      "UPDATE accounts SET revision=999999,authorization='refreshing',refresh_intent='synthetic-refresh' WHERE id=?",
      [.text(context.identity)])
  }
  await #expect(throws: ExecutionError.conflict) {
    try await store.setAccountDisplayName(
      id: context.identity, revision: 999999, displayName: "must preserve completion slot")
  }
  let finished = try await store.failAccountRefresh(
    id: context.identity, credentialVersion: 1,
    intent: "synthetic-refresh", authorizationRequired: true)
  #expect(finished.revision == 1_000_000 && finished.authorization == .requiresAuth)
  await store.close()
}
