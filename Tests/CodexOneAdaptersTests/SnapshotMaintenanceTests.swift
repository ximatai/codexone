import CSQLite
import CodexOneCore
import Foundation
import Testing

@testable import CodexOneAdapters

private func privateSnapshotRoot() throws -> String {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}

@Test func snapshotRestoreHoldsMaintenanceAndInvalidatesOldAuthorization() async throws {
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/source/core.sqlite"
  try FileManager.default.createDirectory(
    atPath: root + "/source", withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  _ = try await store.createKey(
    id: "key", principal: "p", digest: String(repeating: "a", count: 64),
    policy: .init(models: ["m"], limits: syntheticLimits))
  try await store.admit(admission("in-flight"))
  try await store.bind(attempt: "in-flight", object: .init(type: "response", rawID: "old-response"))
  await #expect(throws: ExecutionError.instanceLocked) {
    try await SQLiteSnapshotMaintenance.backup(
      path: path, destination: root + "/online", protection: nil)
  }
  await store.close()
  let manifest = try await SQLiteSnapshotMaintenance.backup(
    path: path, destination: root + "/backup", protection: nil)
  #expect(manifest.schema == 8 && manifest.databaseBytes > 0)
  let current = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  try await current.admit(admission("absent-after-snapshot"))
  await current.close()
  let destination = root + "/restored/core.sqlite"
  let report = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/backup", path: destination, protection: nil)
  #expect(report.backupID == manifest.id && report.baseline == nil)
  let restored = try await SQLiteExecutionStore.open(path: destination, limits: syntheticLimits)
  #expect(restored.isAvailable && !restored.isAdmissionReady)
  #expect(try await restored.snapshot(attempt: "in-flight").state == .unknown)
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await restored.snapshot(attempt: "absent-after-snapshot")
  }
  await #expect(throws: ExecutionError.unauthorized) {
    try await restored.authenticateKey(digest: String(repeating: "a", count: 64))
  }
  await #expect(throws: ExecutionError.unknownObject) {
    try await restored.resolve(
      principal: "p", object: .init(type: "response", rawID: "old-response"))
  }
  await #expect(throws: ExecutionError.maintenanceRequired) {
    try await restored.admit(admission("blocked"))
  }
  await restored.close()
  let baseline = try RestoreBaseline(
    restoreID: report.id, auditReference: "synthetic-ticket-1", missingUnresolvedRequests: 2,
    missingUnresolvedMicros: 25, freezeUntilUnixSeconds: report.minimumFreezeUntilUnixSeconds)
  let reconciled = try await SQLiteSnapshotMaintenance.reconcile(
    path: destination, baseline: baseline)
  #expect(reconciled.baseline == baseline)
  #expect(
    try await SQLiteSnapshotMaintenance.reconcile(path: destination, baseline: baseline)
      == reconciled)
  let frozen = try await SQLiteExecutionStore.open(path: destination, limits: syntheticLimits)
  #expect(!frozen.isAdmissionReady)
  await frozen.close()
  let state = try await SQLiteSnapshotMaintenance.status(path: destination)
  #expect(state?.unresolvedRequests == 2 && state?.unresolvedMicros == 25)
}

@Test func snapshotIntegrityKeyDependenciesAndExclusiveTargetsAreEnforced() async throws {
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  let cipher = try AccountCredentialCipher(hexKey: String(repeating: "5a", count: 32))
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  let context = try AccountCredentialContext(
    identity: "account", namespace: "synthetic/account", version: 1)
  let credential = try AccountCredential(
    accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: nil,
    expiresAtUnixSeconds: 2_000_000_000)
  _ = try await store.createVerifiedAccount(
    id: context.identity, namespace: context.namespace,
    envelope: cipher.seal(credential, context: context))
  await store.close()
  await #expect(throws: ExecutionError.unauthorized) {
    try await SQLiteSnapshotMaintenance.backup(
      path: path, destination: root + "/missing-key", protection: nil)
  }
  let manifest = try await SQLiteSnapshotMaintenance.backup(
    path: path, destination: root + "/backup", protection: cipher)
  #expect(manifest.requiredKeyIDs == [cipher.keyID])
  let wrong = try AccountCredentialCipher(hexKey: String(repeating: "6b", count: 32))
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/backup", path: root + "/wrong/core.sqlite", protection: wrong)
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/wrong"))
  let destination = root + "/restored/core.sqlite"
  _ = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/backup", path: destination, protection: cipher)
  let restored = try await SQLiteExecutionStore.open(path: destination, limits: syntheticLimits)
  #expect(
    try await restored.accountCredential(id: "account").account.authorization == .requiresAuth)
  await restored.close()
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/backup", path: destination, protection: cipher)
  }
  let file = root + "/backup/snapshot.sqlite"
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
  try handle.seekToEnd()
  try handle.write(contentsOf: Data([0]))
  try handle.close()
  await #expect(throws: ExecutionError.invalidCommand) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/backup", path: root + "/corrupt/core.sqlite", protection: cipher)
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/corrupt"))
}

@Test func interruptedRestoreBarrierCannotInitializeAnEmptyReadyDatabase() async throws {
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path + ".restore-pending"))
  await #expect(throws: SnapshotMaintenanceError.self) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func reconciliationRejectsWrongIdentityAndEarlyWindowAndKeepsLifetimeGapReservations()
  async throws
{
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/core.sqlite"
  let store = try await SQLiteExecutionStore.open(path: source, limits: syntheticLimits)
  await store.close()
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: source, destination: root + "/backup", protection: nil)
  let path = root + "/restored/core.sqlite"
  let report = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/backup", path: path, protection: nil)
  let wrong = try RestoreBaseline(
    restoreID: UUID().uuidString, auditReference: "ticket", missingUnresolvedRequests: 0,
    missingUnresolvedMicros: 0, freezeUntilUnixSeconds: report.minimumFreezeUntilUnixSeconds)
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteSnapshotMaintenance.reconcile(path: path, baseline: wrong)
  }
  let early = try RestoreBaseline(
    restoreID: report.id, auditReference: "ticket", missingUnresolvedRequests: 0,
    missingUnresolvedMicros: 0, freezeUntilUnixSeconds: report.restoredUnixSeconds)
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteSnapshotMaintenance.reconcile(path: path, baseline: early)
  }
  let baseline = try RestoreBaseline(
    restoreID: report.id, auditReference: "external-audit-1", missingUnresolvedRequests: 3,
    missingUnresolvedMicros: 80, freezeUntilUnixSeconds: report.minimumFreezeUntilUnixSeconds)
  _ = try await SQLiteSnapshotMaintenance.reconcile(path: path, baseline: baseline)
  // Simulate the next UTC day only in the synthetic persisted time fixture; no product clock override.
  let now = Int64(Date().timeIntervalSince1970)
  try rawSQL(
    path,
    "UPDATE maintenance_state SET restore_json=json_set(restore_json,'$.snapshotUnixSeconds',\(now-172800),'$.restoredUnixSeconds',\(now-86400),'$.baseline.freezeUntilUnixSeconds',\(now/86400*86400))"
  )
  let ready = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  #expect(ready.isAdmissionReady)
  let key = try await ready.createKey(
    id: "fresh", principal: "p", digest: String(repeating: "b", count: 64),
    policy: .init(models: ["m"], limits: syntheticLimits))
  func fresh(_ id: String, reserved: Int64) -> ExecutionAdmission {
    .init(
      attempt: id, owner: .init(principal: "p", key: key.id, namespace: "synthetic", identity: "i"),
      window: "utc-day-\(now/86400)", policyVersion: "p", pricingVersion: "p",
      reservedMicros: reserved, keyRevision: key.revision, model: "m")
  }
  await #expect(throws: ExecutionError.denied) {
    try await ready.admit(fresh("too-expensive", reserved: 21))
  }
  try await ready.admit(fresh("bounded", reserved: 20))
  await #expect(throws: ExecutionError.denied) {
    try await ready.admit(fresh("exceeds-count", reserved: 1))
  }
  #expect(try await ready.snapshot(attempt: "bounded").state == .intent)
  await ready.close()
}

@Test func auditedBaselineAmendmentsUseCASAndCarryAcrossFurtherRestores() async throws {
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/core.sqlite"
  let source = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await source.close()
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: path, destination: root + "/first", protection: nil)
  let restored = root + "/restored/core.sqlite"
  let report = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/first", path: restored, protection: nil)
  let baseline = try RestoreBaseline(
    restoreID: report.id, auditReference: "audit-1", missingUnresolvedRequests: 4,
    missingUnresolvedMicros: 40, freezeUntilUnixSeconds: report.minimumFreezeUntilUnixSeconds)
  _ = try await SQLiteSnapshotMaintenance.reconcile(path: restored, baseline: baseline)
  let amendment = try RestoreBaseline(
    restoreID: report.id, auditReference: "external-evidence-2", missingUnresolvedRequests: 2,
    missingUnresolvedMicros: 20, freezeUntilUnixSeconds: report.minimumFreezeUntilUnixSeconds,
    expectedRevision: 1)
  let changed = try await SQLiteSnapshotMaintenance.reconcile(path: restored, baseline: amendment)
  #expect(changed.baselineRevision == 2 && changed.unresolvedRequests == 2)
  #expect(
    try await SQLiteSnapshotMaintenance.reconcile(path: restored, baseline: amendment) == changed)
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteSnapshotMaintenance.reconcile(path: restored, baseline: baseline)
  }
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: restored, destination: root + "/second", protection: nil)
  let next = root + "/second-restore/core.sqlite"
  let inherited = try await SQLiteSnapshotMaintenance.restore(
    bundle: root + "/second", path: next, protection: nil)
  #expect(inherited.unresolvedRequests == 2 && inherited.unresolvedMicros == 20)
  let drop = try RestoreBaseline(
    restoreID: inherited.id, auditReference: "forgotten-old-gap", missingUnresolvedRequests: 0,
    missingUnresolvedMicros: 0, freezeUntilUnixSeconds: inherited.minimumFreezeUntilUnixSeconds)
  await #expect(throws: ExecutionError.conflict) {
    try await SQLiteSnapshotMaintenance.reconcile(path: next, baseline: drop)
  }
}

@Test func snapshotParentSyncFailurePreventsPublication() async throws {
  let root = try privateSnapshotRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = try await SQLiteExecutionStore.open(
    path: root + "/core.sqlite", limits: syntheticLimits)
  await source.close()
  _ = try await SQLiteSnapshotMaintenance.backup(
    path: root + "/core.sqlite", destination: root + "/bundle", protection: nil)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteSnapshotMaintenance.restore(
      bundle: root + "/bundle", path: root + "/new/core.sqlite", protection: nil,
      syncParent: { _ in throw ExecutionError.storageUnavailable })
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root + "/new").isEmpty)
}

@Test func snapshotFirstReconciliationFreezesItsOwnUTCDay() throws {
  let midnight: Int64 = 20000 * 86400
  let record = RestoreRecord(
    id: UUID().uuidString, backupID: UUID().uuidString,
    snapshotUnixSeconds: midnight - 100, restoredUnixSeconds: midnight - 1,
    inheritedUnresolvedRequests: 0, inheritedUnresolvedMicros: 0)
  func baseline(_ cutoff: Int64) throws -> RestoreBaseline {
    try RestoreBaseline(
      restoreID: record.id, auditReference: "synthetic-midnight",
      missingUnresolvedRequests: 0, missingUnresolvedMicros: 0, freezeUntilUnixSeconds: cutoff)
  }
  #expect(record.minimumReconciliationFreeze(at: midnight + 1) == midnight + 86400)
  #expect(throws: ExecutionError.conflict) {
    try record.reconciling(baseline(midnight), at: midnight + 1)
  }
  let reconciled = try record.reconciling(baseline(midnight + 86400), at: midnight + 1)
  #expect(!reconciled.allowsAdmission(at: midnight + 2))
  #expect(reconciled.minimumReconciliationFreeze(at: midnight + 172800) == midnight + 86400)
  #expect(
    try reconciled.reconciling(baseline(midnight + 86400), at: midnight + 172800) == reconciled)
}
