import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private let keyOld = String(repeating: "6a", count: 32)
private let keyNew = String(repeating: "7b", count: 32)
private func keyRoot() throws -> String {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}
private func seedKeys(_ path: String, count: Int = 20) async throws {
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let app = AccountCredentials(
    store: store, protection: try AccountCredentialCipher(hexKey: keyOld))
  for number in 0..<count {
    _ = try await app.importVerified(
      id: "synthetic-\(number)", namespace: "synthetic/key/\(number)",
      credential: .init(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
        expiresAtUnixSeconds: 2_000_000_000))
  }
  _ = try await app.beginRefresh(id: "synthetic-0", revision: 1)
  await store.close()
}

@Test func reencryptionPagesPreserveContextAndResumeOnlyTheirTargetKey() async throws {
  let root = try keyRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try await seedKeys(path)
  let ring = try AccountCredentialCipher(activeHexKey: keyNew, decryptOnlyHexKeys: [keyOld])
  // Actual page commit, then an injected owner failure: mixed versions and checkpoint survive together.
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: ring, backupDestination: root + "/before",
      beforePageCommit: { _ in }, afterPageCommit: { _ in throw ExecutionError.storageUnavailable })
  }
  let progress = try await SQLiteKeyMaintenance.status(path: path, protection: ring)
  #expect(progress.checkpoint?.rewritten == 8 && progress.checkpoint?.complete == false)
  #expect(progress.requiredCurrentKeyIDs.count == 2)
  await #expect(throws: KeyMaintenanceError.incompleteReencryption) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: .init(hexKey: keyNew), backupDestination: nil)
  }
  let wrongTarget = try AccountCredentialCipher(activeHexKey: keyOld, decryptOnlyHexKeys: [keyNew])
  await #expect(throws: KeyMaintenanceError.wrongActiveKey) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: wrongTarget, backupDestination: nil)
  }
  let complete = try await SQLiteKeyMaintenance.reencrypt(
    path: path, protection: ring, backupDestination: nil)
  #expect(complete.checkpoint?.complete == true && complete.checkpoint?.rewritten == 20)
  #expect(complete.requiredCurrentKeyIDs == [ring.keyID])
  let db = try SQLiteConnection(path: path, existingOnly: true)
  #expect(
    try db.scalar(
      "SELECT COUNT(*) FROM accounts WHERE revision=1 AND credential_version=1 AND authorization='ready'"
    ) == 19)
  #expect(
    try db.scalar(
      "SELECT COUNT(*) FROM accounts WHERE revision=2 AND credential_version=1 AND authorization='refreshing' AND refresh_intent IS NOT NULL"
    ) == 1)
  db.shutdown()
  #expect(
    try await SQLiteKeyMaintenance.reencrypt(path: path, protection: ring, backupDestination: nil)
      .checkpoint == complete.checkpoint)
  let oldBackup = try await SQLiteSnapshotMaintenance.verifyBackup(
    bundle: root + "/before", protection: ring)
  #expect(oldBackup.requiredKeyIDs == [try AccountCredentialCipher(hexKey: keyOld).keyID])
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.verifyBackup(
      bundle: root + "/before", protection: .init(hexKey: keyNew))
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(
    try await store.accountCredential(id: "synthetic-0").account.authorization == .authUncertain)
  await store.close()
}

@Test func failedReencryptionPageRollsBackEnvelopesAndCheckpoint() async throws {
  let root = try keyRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try await seedKeys(path)
  let ring = try AccountCredentialCipher(activeHexKey: keyNew, decryptOnlyHexKeys: [keyOld])
  let failureDB = try SQLiteConnection(path: path, existingOnly: true)
  try failureDB.exec(
    "CREATE TRIGGER synthetic_reencryption_failure BEFORE UPDATE OF sealed_credential ON accounts WHEN OLD.id='synthetic-1' BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END;"
  )
  failureDB.shutdown()
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: ring, backupDestination: root + "/before")
  }
  let status = try await SQLiteKeyMaintenance.status(path: path, protection: ring)
  #expect(status.checkpoint?.rewritten == 0 && status.checkpoint?.complete == false)
  #expect(status.requiredCurrentKeyIDs == [try AccountCredentialCipher(hexKey: keyOld).keyID])
  let repairedDB = try SQLiteConnection(path: path, existingOnly: true)
  try repairedDB.exec("DROP TRIGGER synthetic_reencryption_failure")
  repairedDB.shutdown()
  let result = try await SQLiteKeyMaintenance.reencrypt(
    path: path, protection: ring, backupDestination: nil)
  #expect(result.checkpoint?.rewritten == 20 && result.checkpoint?.complete == true)
}

@Test func reencryptionRefusesOnlineOwnerBadKeysAndIncompleteBackup() async throws {
  let root = try keyRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try await seedKeys(path, count: 2)
  let ring = try AccountCredentialCipher(activeHexKey: keyNew, decryptOnlyHexKeys: [keyOld])
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await #expect(throws: ExecutionError.instanceLocked) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: ring, backupDestination: root + "/online")
  }
  await store.close()
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: .init(hexKey: keyNew), backupDestination: root + "/bad-key")
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/bad-key"))
  try FileManager.default.createDirectory(
    atPath: root + "/existing", withIntermediateDirectories: false)
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteKeyMaintenance.reencrypt(
      path: path, protection: ring, backupDestination: root + "/existing")
  }
  #expect(try await SQLiteKeyMaintenance.status(path: path, protection: ring).checkpoint == nil)
}

@Test func retirementChecksRetainedOldBackupsAndRestoreEvidenceBeforeAuditing() async throws {
  let root = try keyRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try await seedKeys(path, count: 2)
  let ring = try AccountCredentialCipher(activeHexKey: keyNew, decryptOnlyHexKeys: [keyOld])
  _ = try await SQLiteKeyMaintenance.reencrypt(
    path: path, protection: ring, backupDestination: root + "/old")
  // A historical v7 completed bundle uses the identical envelope/maintenance columns.
  try rawSQL(
    root + "/old/snapshot.sqlite",
    "ALTER TABLE accounts DROP COLUMN display_name; DROP INDEX attempts_in_flight; PRAGMA user_version=7"
  )
  let hash = try SQLiteSnapshotMaintenance.fingerprint(root + "/old/snapshot.sqlite")
  let manifestURL = URL(fileURLWithPath: root + "/old/manifest.json")
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
  manifest["schema"] = 7
  manifest["databaseBytes"] = hash.0
  manifest["databaseSHA256"] = hash.1
  try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
  try FileManager.default.copyItem(
    atPath: root + "/old/snapshot.sqlite", toPath: root + "/raw-pre-v8.sqlite")
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/old", path: root + "/missing-key-target/core.sqlite",
      protection: .init(hexKey: keyNew))
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/missing-key-target"))
  let restored = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/old", path: root + "/drill/core.sqlite", protection: ring)
  let inventoryFile = root + "/inventory.json"
  func inventory(_ complete: Bool, _ drills: [String], audit: String = "synthetic-raw-drill") throws
  {
    try JSONSerialization.data(withJSONObject: [
      "format": 1, "inventoryComplete": complete,
      "auditReference": "synthetic-retirement", "legacyDatabases": [root + "/raw-pre-v8.sqlite"],
      "legacyRestoreAuditReference": audit,
      "retainedBackups": [root + "/old"],
      "restoreDrills": drills,
    ]).write(to: URL(fileURLWithPath: inventoryFile))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inventoryFile)
  }
  try inventory(false, [root + "/drill"])
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.checkRetirement(
      path: path, protection: ring, inventoryFile: inventoryFile)
  }
  try inventory(true, [])
  await #expect(throws: ExecutionError.denied) {
    try await SQLiteKeyMaintenance.checkRetirement(
      path: path, protection: ring, inventoryFile: inventoryFile)
  }
  try inventory(true, [root + "/drill"], audit: "")
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.checkRetirement(
      path: path, protection: ring, inventoryFile: inventoryFile)
  }
  try inventory(true, [root + "/drill"])
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.checkRetirement(
      path: path, protection: .init(hexKey: keyNew), inventoryFile: inventoryFile)
  }
  let evidence = try await SQLiteKeyMaintenance.checkRetirement(
    path: path, protection: ring, inventoryFile: inventoryFile)
  let object = try #require(JSONSerialization.jsonObject(with: evidence) as? [String: Any])
  #expect(object["verifiedRestoreIDs"] as? [String] == [restored.id])
  #expect(object["verifiedLegacySHA256"] as? [String] == [hash.1])
  let restoredDB = try SQLiteConnection(path: root + "/drill/core.sqlite", existingOnly: true)
  #expect(try restoredDB.scalar("PRAGMA user_version") == 9)
  restoredDB.shutdown()
  #expect(object["requiredCurrentKeyIDs"] as? [String] == [ring.keyID])
  #expect(
    object["requiredBackupKeyIDs"] as? [String] == [
      try AccountCredentialCipher(hexKey: keyOld).keyID
    ])
  #expect(!String(decoding: evidence, as: UTF8.self).contains(root))
  let db = try SQLiteConnection(path: path, existingOnly: true)
  #expect(
    try db.scalar("SELECT COUNT(*) FROM maintenance_events WHERE action='key_retirement_checked'")
      == 1)
  db.shutdown()
}

@Test(arguments: [7, 8, 9])
func backupSchemaMislabelIsRejectedBeforeVerificationRetirementOrTargetCreation(actualSchema: Int)
  async throws
{
  let root = try keyRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try await seedKeys(path, count: 2)
  let cipher = try AccountCredentialCipher(hexKey: keyOld)
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: path, destination: root + "/bundle", protection: cipher)
  if actualSchema < 9 {
    try rawSQL(
      root + "/bundle/snapshot.sqlite",
      "ALTER TABLE accounts DROP COLUMN display_name; DROP INDEX attempts_in_flight; PRAGMA user_version=\(actualSchema)"
    )
  }
  let hash = try SQLiteSnapshotMaintenance.fingerprint(root + "/bundle/snapshot.sqlite")
  let file = URL(fileURLWithPath: root + "/bundle/manifest.json")
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  manifest["schema"] = actualSchema == 7 ? 8 : 7
  manifest["databaseBytes"] = hash.0
  manifest["databaseSHA256"] = hash.1
  try JSONSerialization.data(withJSONObject: manifest).write(to: file)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.verifyBackup(bundle: root + "/bundle", protection: cipher)
  }
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/bundle", path: root + "/refused/core.sqlite", protection: cipher)
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/refused"))
  let inventory = URL(fileURLWithPath: root + "/inventory.json")
  try JSONSerialization.data(withJSONObject: [
    "format": 1, "inventoryComplete": true,
    "auditReference": "synthetic-schema-mismatch", "retainedBackups": [root + "/bundle"],
    "restoreDrills": [], "legacyDatabases": [],
  ]).write(to: inventory)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inventory.path)
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteKeyMaintenance.checkRetirement(
      path: path, protection: cipher, inventoryFile: inventory.path)
  }
}
