import CSQLite
import CodexOneCore
import Dispatch
import Foundation
import Synchronization
import Testing
import Vapor

@testable import CodexOneAdapters

private func backupRoot() throws -> String {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}
private func backupNames(_ root: String) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: root).filter {
    $0.hasPrefix("online-") && !$0.hasSuffix(".partial")
  }.sorted()
}

@Test func onlineBackupCopiesAlongsideRealAdmissionAndSettlementAndRestores() async throws {
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let context = try AccountCredentialContext(
    identity: "account", namespace: "synthetic/account", version: 1)
  let credential = try AccountCredential(
    accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  _ = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace,
    envelope: cipher.seal(credential, context: context))
  try await store.perform { db in
    try db.exec("CREATE TABLE synthetic_padding (data BLOB)")
    try db.exec("INSERT INTO synthetic_padding VALUES(zeroblob(8388608))")
  }
  let entered = Mutex(false)
  let steps = Mutex(0)
  let resume = DispatchSemaphore(value: 0)
  let backup = try SQLiteOnlineBackup(
    primary: store, directory: root, protection: cipher,
    beforeStep: {
      let step = steps.withLock {
        $0 += 1
        return $0
      }
      if step == 2 {
        entered.withLock { $0 = true }
        guard resume.wait(timeout: .now() + 5) == .success else {
          throw ExecutionError.storageUnavailable
        }
      }
    })
  let task = Task { await backup.performBackup() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !entered.withLock({ $0 }) && ContinuousClock.now < deadline { await Task.yield() }
  try #require(entered.withLock { $0 })
  // These use the primary writer and its real transactions while the snapshot has many steps.
  for i in 0..<20 {
    try await store.admit(admission("online-\(i)", reserved: 1))
    try await store.finalize(attempt: "online-\(i)", evidence: usage(amount: 1))
  }
  resume.signal()
  await task.value
  #expect(backup.backupObservation.lastFailure == nil)
  #expect(backup.backupObservation.retainedCount == 1)
  #expect(store.isAdmissionReady)
  let bundle = root + "/" + (try #require(backupNames(root).first))
  let verified = try await SQLiteSnapshotMaintenance.verifyBackup(
    bundle: bundle, protection: cipher)
  #expect(verified.databaseBytes > 8_000_000)
  #expect(verified.requiredKeyIDs == [cipher.keyID])
  // The live service still owns its lock; offline backup remains forbidden.
  await #expect(throws: ExecutionError.instanceLocked) {
    try await SQLiteSnapshotMaintenance.backup(
      path: path, destination: root + "/offline", protection: nil)
  }
  let restored = try await SQLiteSnapshotMaintenance.restore(
    bundle: bundle, path: root + "/restored/core.sqlite", protection: cipher)
  #expect(restored.backupID == verified.id && restored.baseline == nil)
  let restoredDB = try SQLiteConnection(path: root + "/restored/core.sqlite", existingOnly: true)
  #expect(try restoredDB.scalar("SELECT length(data) FROM synthetic_padding") == 8_388_608)
  #expect(
    try restoredDB.rows("SELECT authorization FROM accounts") {
      String(cString: sqlite3_column_text($0, 0))
    } == ["requires_auth"])
  restoredDB.shutdown()
  await store.close()
}

@Test func onlineBackupRetainsSevenOnlyAfterVerifiedPublicationAndCleansPartial() async throws {
  let time = TestWallClock()
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits, clock: time.clock)
  let backup = try store.makeOnlineBackup(directory: root, protection: nil)
  #expect(backup.backupObservation.enabledUnixSeconds == time.clock.unixSeconds)
  await backup.performBackup()
  let first = try #require(backupNames(root).first)
  for _ in 0..<6 {
    time.advance(seconds: 1)
    await backup.performBackup()
  }
  #expect(try backupNames(root).count == 7)
  let old = try backupNames(root)
  let fails = try SQLiteOnlineBackup(
    primary: store, directory: root, protection: nil,
    beforeStep: { throw ExecutionError.storagePressure })
  await fails.performBackup()
  #expect(fails.backupObservation.lastFailure == .insufficientSpace)
  #expect(fails.backupObservation.lastFailureUnixSeconds == time.clock.unixSeconds)
  #expect(try backupNames(root) == old)
  let invalid = try SQLiteOnlineBackup(
    primary: store, directory: root, protection: nil,
    beforeVerify: { bundle in
      let url = URL(fileURLWithPath: bundle + "/snapshot.sqlite")
      let file = try FileHandle(forWritingTo: url)
      try file.write(contentsOf: Data("synthetic-corruption".utf8))
      try file.close()
    })
  await invalid.performBackup()
  #expect(invalid.backupObservation.lastFailure == .verificationFailed)
  #expect(try backupNames(root) == old)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root).contains { $0.hasSuffix(".partial") })
  time.advance(seconds: 1)
  await backup.performBackup()
  #expect(try backupNames(root).count == 7)
  #expect(!FileManager.default.fileExists(atPath: root + "/" + first))
  #expect(
    try !FileManager.default.contentsOfDirectory(atPath: root).contains { $0.hasSuffix(".partial") }
  )
  let restarted = try store.makeOnlineBackup(directory: root, protection: nil)
  #expect(restarted.backupObservation.lastSuccessUnixSeconds == time.clock.unixSeconds)
  #expect(restarted.backupObservation.retainedCount == 7)
  #expect(restarted.backupObservation.totalBytes > restarted.backupObservation.largestBundleBytes)
  try await store.admit(admission("still-serving"))
  try await store.finalize(attempt: "still-serving", evidence: usage(amount: 1))
  await store.close()
}

@Test func onlineBackupDirectoryFailuresDoNotAffectCoreAndConfigurationRejectsUnsafeDirectories()
  async throws
{
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits)
  let directory = root + "/backups"
  try FileManager.default.createDirectory(
    atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  #expect(throws: (any Error).self) {
    try SQLiteSnapshotMaintenance.validateBackupDirectory("relative")
  }
  #expect(throws: (any Error).self) {
    try SQLiteSnapshotMaintenance.validateBackupDirectory(root + "/absent")
  }
  let backup = try store.makeOnlineBackup(directory: directory, protection: nil)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
  #expect(throws: (any Error).self) {
    try SQLiteSnapshotMaintenance.validateBackupDirectory(directory)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
  #expect(throws: (any Error).self) {
    try SQLiteSnapshotMaintenance.validateBackupDirectory(directory)
  }
  await backup.performBackup()
  #expect(backup.backupObservation.lastFailure == .directoryUnavailable)
  #expect(backup.backupObservation.lastFailureUnixSeconds != nil)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
  let link = root + "/link"
  try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
  #expect(throws: (any Error).self) { try SQLiteSnapshotMaintenance.validateBackupDirectory(link) }
  try await store.admit(admission("directory-failed"))
  try await store.finalize(attempt: "directory-failed", evidence: usage(amount: 1))
  #expect(store.isAdmissionReady)
  await backup.performBackup()
  #expect(backup.backupObservation.retainedCount == 1)
  await store.close()
}

@Test func onlineBackupSkipsAllNonNormalStorageAndCancelsWithoutPublishing() async throws {
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let available = Mutex(Int64(2_000_000_000))
  let store = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits, storagePolicy: .standard,
    available: { _ in
      let value = available.withLock { $0 }
      if value < 0 { throw ExecutionError.storagePressure }
      return value
    })
  let backup = try store.makeOnlineBackup(directory: root, protection: nil)
  for (bytes, pressure) in [
    (Int64(200_000_000), StoragePressure.degraded), (100_000_000, .blocked), (-1, .unknown),
  ] {
    available.withLock { $0 = bytes }
    try await store.maintainStorage()
    #expect(store.storageObservation.pressure == pressure)
    await backup.performBackup()
    #expect(backup.backupObservation.skippedPressure == pressure)
    #expect(backup.backupObservation.lastSkippedUnixSeconds != nil)
    #expect(backup.backupObservation.lastFailure == nil)
    #expect(try backupNames(root).isEmpty)
  }
  available.withLock { $0 = 2_000_000_000 }
  try await store.maintainStorage()
  let copying = Mutex(false)
  let cancelled = try SQLiteOnlineBackup(
    primary: store, directory: root, protection: nil,
    beforeCopy: {
      copying.withLock { $0 = true }
      Thread.sleep(forTimeInterval: 0.05)
    })
  let task = Task { await cancelled.performBackup() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !copying.withLock({ $0 }) && ContinuousClock.now < deadline { await Task.yield() }
  try #require(copying.withLock { $0 })
  task.cancel()
  await task.value
  #expect(cancelled.backupObservation.lastFailure == .cancelled)
  #expect(try backupNames(root).isEmpty)
  #expect(store.isAdmissionReady)
  await store.close()
}

@Test func backupAttentionUsesStrictAgeAndSizeBoundaries() {
  let now: Int64 = 2_000_000_000
  var observation = BackupObservation()
  #expect(AttentionRules.backup(observation, now: now).map(\.kind) == ["backup_disabled"])
  observation.enabled = true
  observation.enabledUnixSeconds = now
  #expect(AttentionRules.backup(observation, now: now + 36 * 3600).isEmpty)
  #expect(AttentionRules.backup(observation, now: now + 36 * 3600 + 1).first?.severity == "warning")
  observation.lastSuccessUnixSeconds = now
  #expect(AttentionRules.backup(observation, now: now + 72 * 3600).first?.severity == "warning")
  #expect(
    AttentionRules.backup(observation, now: now + 72 * 3600 + 1).first?.severity == "critical")
  observation.totalBytes = 5 * 1024 * 1024 * 1024
  observation.largestBundleBytes = 768 * 1024 * 1024
  #expect(AttentionRules.backup(observation, now: now).isEmpty)
  observation.totalBytes += 1
  #expect(AttentionRules.backup(observation, now: now).first?.kind == "backup_size")
  observation.totalBytes = 0
  observation.largestBundleBytes += 1
  #expect(AttentionRules.backup(observation, now: now).first?.kind == "backup_size")
}

@Test func backupStorageRouteReturnsSanitizedHealthWithAuthentication() async throws {
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let secret = "synthetic-backup-administrator-secret"
  let secretFile = root + "/admin"
  try Data(secret.utf8).write(to: URL(fileURLWithPath: secretFile))
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile)
  let store = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits)
  let backup = try store.makeOnlineBackup(directory: root, protection: nil)
  await backup.performBackup()
  let api = try await KeyAdminAPI.load(
    path: secretFile, store: store, storageMonitoring: store, backup: backup)
  let app = try await Application.make(.testing)
  api.register(app)
  api.bind(port: 19876)
  let request = Request(
    application: app, method: .GET, url: URI(path: "/api/runtime/storage"),
    headers: ["authorization": "Bearer " + secret], on: app.eventLoopGroup.next())
  let response = try await app.responder.respond(to: request).get()
  #expect(response.status == .ok)
  #expect(response.headers.first(name: "cache-control") == "no-store")
  let body = response.body.string ?? ""
  let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
  let health = try #require(json["backup"] as? [String: Any])
  #expect(health["enabled"] as? Bool == true)
  #expect(health["retainedCount"] as? Int == 1)
  #expect(health["lastSuccessUnixSeconds"] as? Int64 != nil)
  #expect(!body.contains(root) && !body.contains(secret))
  let unauthorized = Request(
    application: app, method: .GET, url: URI(path: "/api/runtime/storage"),
    headers: ["host": "127.0.0.1:19876"], on: app.eventLoopGroup.next())
  #expect(try await app.responder.respond(to: unauthorized).get().status == .unauthorized)
  try await app.asyncShutdown()
  await store.close()
}

@Test func onlineBackupSingleFlightDoesNotTouchUnmanagedBundles() async throws {
  let root = try backupRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits)
  let manual = root + "/manual-bundle"
  try FileManager.default.createDirectory(
    atPath: manual, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let sentinel = manual + "/sentinel"
  try Data("synthetic-manual-backup".utf8).write(to: URL(fileURLWithPath: sentinel))
  let entered = Mutex(0)
  let resume = DispatchSemaphore(value: 0)
  let backup = try SQLiteOnlineBackup(
    primary: store, directory: root, protection: nil,
    beforeCopy: {
      entered.withLock { $0 += 1 }
      guard resume.wait(timeout: .now() + 5) == .success else {
        throw ExecutionError.storageUnavailable
      }
    })
  let first = Task { await backup.performBackup() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while entered.withLock({ $0 }) == 0 && ContinuousClock.now < deadline { await Task.yield() }
  try #require(entered.withLock { $0 } == 1)
  await backup.performBackup()
  #expect(entered.withLock { $0 } == 1)
  resume.signal()
  await first.value
  #expect(backup.backupObservation.retainedCount == 1)
  #expect(try String(contentsOfFile: sentinel, encoding: .utf8) == "synthetic-manual-backup")
  await store.close()
}
