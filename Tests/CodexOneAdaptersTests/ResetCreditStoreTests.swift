import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

@Test func resetCreditIntentSurvivesUnknownRestartAndRejectsDifferentCredit() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  let account = try await app.importVerified(
    id: "account", namespace: "synthetic/account",
    credential: .init(
      accessToken: "synthetic", refreshToken: "synthetic", idToken: nil,
      expiresAtUnixSeconds: 2_000_000_000))
  #expect(try await store.resetCreditState(id: account.id).settings.autoUseBeforeExpiry == false)
  let attempt = try await store.beginResetCreditAttempt(
    account: account, creditID: "credit-a", automatic: false)
  try await store.finishResetCreditAttempt(
    id: account.id, attempt: attempt, result: .init(code: .unknown))
  await store.close()
  let reopened = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  #expect(try await reopened.resetCreditState(id: account.id).intent == attempt.intent)
  await #expect(throws: ExecutionError.conflict) {
    try await reopened.beginResetCreditAttempt(
      account: account, creditID: "credit-b", automatic: false)
  }
  let retry = try await reopened.beginResetCreditAttempt(
    account: account, creditID: nil, automatic: false)
  #expect(retry.intent == attempt.intent && retry.auditID != attempt.auditID)
  try await reopened.finishResetCreditAttempt(
    id: account.id, attempt: retry, result: .init(code: .alreadyRedeemed))
  #expect(try await reopened.resetCreditState(id: account.id).intent == nil)
  #expect(
    try await reopened.perform { try $0.scalar("SELECT COUNT(*) FROM reset_credit_events") } == 2)
  await reopened.close()
}

@Test func resetCreditStorageFailurePreventsSendAndFailedCompletionKeepsID() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  let account = try await app.importVerified(
    id: "account", namespace: "synthetic/account",
    credential: .init(
      accessToken: "synthetic", refreshToken: "synthetic", idToken: nil,
      expiresAtUnixSeconds: 2_000_000_000))
  let attempt = try await store.beginResetCreditAttempt(
    account: account, creditID: nil, automatic: false)
  try rawSQL(
    path,
    "CREATE TRIGGER fail_reset BEFORE UPDATE ON reset_credit_events BEGIN SELECT RAISE(ABORT,'synthetic'); END"
  )
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.finishResetCreditAttempt(
      id: account.id, attempt: attempt, result: .init(code: .reset, windowsReset: 1))
  }
  #expect(try await store.resetCreditState(id: account.id).intent == attempt.intent)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await store.beginResetCreditAttempt(account: account, creditID: nil, automatic: false)
  }
  await store.close()
}

@Test func resetCreditV10MigrationBacksUpAndRestorePreservesIntentWithAutomationOff() async throws {
  let path = try temporaryExecutionPath()
  let root = (path as NSString).deletingLastPathComponent
  defer { try? FileManager.default.removeItem(atPath: root) }
  var store = try await SQLiteExecutionStore.open(
    path: path, limits: syntheticLimits, clock: testClock)
  await store.close()
  try rawSQL(
    path, "DROP TABLE reset_credit_events; DROP TABLE account_reset_credits; PRAGMA user_version=10"
  )
  await #expect(throws: ExecutionError.incompatibleSchema) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: testClock)
  }
  try await SQLiteExecutionStore.migrate(path: path, clock: testClock)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root).contains {
      $0.contains(".pre-v11-") && $0.hasSuffix(".sqlite")
    })
  store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits, clock: testClock)
  #expect(try await store.perform { try $0.scalar("PRAGMA user_version") } == 11)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let app = AccountCredentials(store: store, protection: cipher, clock: testClock)
  var account = try await app.importVerified(
    id: "account", namespace: "synthetic/account",
    credential: .init(
      accessToken: "synthetic", refreshToken: "synthetic", idToken: nil,
      expiresAtUnixSeconds: 2_000_000_000))
  _ = try await store.setResetCreditSettings(
    id: account.id, revision: account.revision,
    settings: .init(autoUseBeforeExpiry: true, leadHours: 48))
  account = try await store.accountCredential(id: account.id).account
  let attempt = try await store.beginResetCreditAttempt(
    account: account, creditID: "credit", automatic: false)
  await store.close()
  let manifest = try await SQLiteSnapshotMaintenance.backup(
    path: path, destination: root + "/bundle", protection: cipher, clock: testClock)
  #expect(manifest.schema == 11)
  _ = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/bundle", path: root + "/restored/core.sqlite", protection: cipher,
    clock: testClock)
  let restored = try await SQLiteExecutionStore.open(
    path: root + "/restored/core.sqlite", limits: syntheticLimits, clock: testClock)
  let state = try await restored.resetCreditState(id: account.id)
  #expect(
    !state.settings.autoUseBeforeExpiry && state.settings.leadHours == 48
      && state.intent == attempt.intent)
  #expect(!restored.isAdmissionReady)
  #expect(
    try await restored.accountCredential(id: account.id).account.authorization == .requiresAuth)
  await restored.close()
}
