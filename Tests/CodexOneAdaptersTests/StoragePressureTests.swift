import CSQLite
import CodexOneCore
import Foundation
import Synchronization
import Testing

@testable import CodexOneAdapters

private let mib: Int64 = 1_048_576
private func pressurePolicy() throws -> StorageSpacePolicy {
  try .init(
    reserveBytes: mib, stopBytes: 2 * mib, resumeBytes: 4 * mib,
    optionalBytes: 8 * mib, walSoftBytes: mib, walStopBytes: 2 * mib)
}
private final class SpaceValue: Sendable { let value = Mutex<Int64?>(32 * mib) }
private struct PressureFixture {
  let path: String
  let space: SpaceValue
  let store: SQLiteExecutionStore
  static func make() async throws -> Self {
    let path = try temporaryExecutionPath()
    let space = SpaceValue()
    let store = try await SQLiteExecutionStore.open(
      path: path, limits: syntheticLimits,
      storagePolicy: pressurePolicy(),
      available: { _ in
        guard let available = space.value.withLock({ $0 }) else {
          throw ExecutionError.storagePressure
        }
        return available
      })
    return Self(path: path, space: space, store: store)
  }
  func close() async {
    await store.close()
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
}

@Test func storageWatermarksYieldOptionalWorkThenBlockAdmissionButPreserveFinalization()
  async throws
{
  let f = try await PressureFixture.make()
  defer {
    try? FileManager.default.removeItem(atPath: (f.path as NSString).deletingLastPathComponent)
  }
  let reader = try await f.store.makeUsageReader()
  #expect(f.store.storageObservation.reserveBytes == mib)
  let key = try await f.store.createKey(
    id: "protected", principal: "p", digest: String(repeating: "b", count: 64),
    policy: .init(models: ["m"], limits: syntheticLimits))
  try await f.store.admit(admission("held"))
  f.space.value.withLock { $0 = 6 * mib }
  try await f.store.maintainStorage()
  #expect(f.store.storageObservation.pressure == .degraded && f.store.isAdmissionReady)
  await #expect(throws: ExecutionError.capacity) { try await reader.usageOptions() }
  await #expect(throws: ExecutionError.storagePressure) {
    try await f.store.createKey(
      id: "blocked", principal: "p", digest: String(repeating: "a", count: 64),
      policy: .init(models: ["m"], limits: syntheticLimits))
  }
  let revoked = try await f.store.updateKey(
    id: key.id, revision: key.revision, enabled: false, policy: key.policy)
  #expect(!revoked.enabled)
  try await f.store.admit(admission("last-before-stop"))
  f.space.value.withLock { $0 = mib }
  try await f.store.maintainStorage()
  #expect(f.store.isAvailable && !f.store.isAdmissionReady)
  await #expect(throws: ExecutionError.storagePressure) {
    try await f.store.admit(admission("refused"))
  }
  try await f.store.bind(attempt: "held", object: .init(type: "response", rawID: "synthetic-id"))
  try await f.store.finalize(attempt: "held", evidence: usage())
  #expect(try await f.store.snapshot(attempt: "held").state == .settled)
  #expect(f.store.storageObservation.reserveBytes == 0)
  f.space.value.withLock { $0 = 3 * mib }
  try await f.store.maintainStorage()
  #expect(!f.store.isAdmissionReady)
  f.space.value.withLock { $0 = 32 * mib }
  try await f.store.maintainStorage()
  #expect(f.store.isAdmissionReady && f.store.storageObservation.reserveBytes == mib)
  await reader.close()
  await f.store.close()
  let recovered = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits,
    storagePolicy: pressurePolicy(), available: { _ in 32 * mib })
  #expect(try await recovered.snapshot(attempt: "last-before-stop").state == .unknown)
  #expect(try await recovered.snapshot(attempt: "held").state == .settled)
  await recovered.close()
}

@Test func unknownSpaceFailsClosedWithoutInventingAStorageFailure() async throws {
  let f = try await PressureFixture.make()
  try await f.store.admit(admission("held"))
  f.space.value.withLock { $0 = nil }
  try await f.store.maintainStorage()
  #expect(f.store.storageObservation.pressure == .unknown && f.store.isAvailable)
  await #expect(throws: ExecutionError.storagePressure) {
    try await f.store.admit(admission("refused"))
  }
  #expect(try await f.store.listKeys(after: nil).isEmpty)
  try await f.store.finalize(attempt: "held", evidence: nil)
  #expect(try await f.store.snapshot(attempt: "held").state == .unknown)
  await f.close()
}

@Test func pinnedReaderWALBlocksNewWorkAndNonblockingCheckpointRecoversAfterReaderEnds()
  async throws
{
  let f = try await PressureFixture.make()
  try await f.store.admit(admission("held"))
  try await f.store.perform { try $0.exec("PRAGMA wal_autocheckpoint=0") }
  let pinned = try SQLiteConnection(readOnlyPath: f.path)
  try pinned.exec("BEGIN")
  _ = try pinned.scalar("SELECT COUNT(*) FROM attempts")
  try await f.store.perform { db in
    try db.exec(
      "CREATE TABLE synthetic_growth(payload BLOB); INSERT INTO synthetic_growth VALUES(zeroblob(4194304))"
    )
  }
  let started = ContinuousClock.now
  try await f.store.maintainStorage()
  #expect(ContinuousClock.now - started < .seconds(1))
  #expect(
    f.store.storageObservation.checkpointBusy && f.store.storageObservation.walBytes >= 2 * mib)
  await #expect(throws: ExecutionError.storagePressure) {
    try await f.store.admit(admission("refused"))
  }
  try await f.store.finalize(attempt: "held", evidence: usage())
  try pinned.exec("ROLLBACK")
  pinned.shutdown()
  try await f.store.maintainStorage()
  #expect(f.store.storageObservation.walBytes == 0 && f.store.isAdmissionReady)
  #expect(try await f.store.snapshot(attempt: "held").state == .settled)
  await f.close()
}

@Test func sparseReserveCannotMasqueradeAsAllocatedSettlementSpace() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await store.close()
  let file = URL(fileURLWithPath: path + ".settlement-reserve")
  try FileManager.default.removeItem(at: file)
  FileManager.default.createFile(
    atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
  let handle = try FileHandle(forWritingTo: file)
  try handle.truncate(atOffset: 64 * 1024 * 1024)
  try handle.close()
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
}

@Test func queuedAdmissionRechecksSpaceAfterWaitingInsteadOfTrustingCachedReadiness() async throws {
  let f = try await PressureFixture.make()
  let entered = Mutex(false)
  let release = DispatchSemaphore(value: 0)
  let blocker = Task {
    try await f.store.perform { _ in
      entered.withLock { $0 = true }
      release.wait()
    }
  }
  while !entered.withLock({ $0 }) { await Task.yield() }
  let pending = Task { try await f.store.admit(admission("waited")) }
  while f.store.storageObservation.regularQueued < 2 { await Task.yield() }
  #expect(f.store.isAdmissionReady)
  f.space.value.withLock { $0 = mib }
  release.signal()
  try await blocker.value
  await #expect(throws: ExecutionError.storagePressure) { try await pending.value }
  await #expect(throws: ExecutionError.unknownAttempt) {
    try await f.store.snapshot(attempt: "waited")
  }
  #expect(f.store.isAvailable && !f.store.isAdmissionReady)
  await f.close()
}

@Test func actualSQLiteFullPreservesIntentAndRequiresRecoveryEvenWhenVolumeSampleIsHealthy()
  async throws
{
  let f = try await PressureFixture.make()
  defer {
    try? FileManager.default.removeItem(atPath: (f.path as NSString).deletingLastPathComponent)
  }
  try await f.store.admit(admission("durable-before-full"))
  try await f.store.perform { db in
    try db.exec("CREATE TABLE synthetic_full(payload BLOB)")
    let pages = try db.scalar("PRAGMA page_count")
    try db.exec("PRAGMA max_page_count=\(pages)")
  }
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await f.store.perform {
      try $0.exec("INSERT INTO synthetic_full VALUES(zeroblob(8388608))")
    }
  }
  #expect(!f.store.isAvailable)
  #expect(try await f.store.snapshot(attempt: "durable-before-full").state == .intent)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await f.store.admit(admission("refused-after-full"))
  }
  await f.store.close()
  let recovered = try await SQLiteExecutionStore.open(
    path: f.path, limits: syntheticLimits, storagePolicy: pressurePolicy(),
    available: { _ in 32 * mib })
  #expect(try await recovered.snapshot(attempt: "durable-before-full").state == .unknown)
  await recovered.close()
}

@Test func unknownReserveFileIsRejectedWithoutOverwritingItsContents() async throws {
  let path = try temporaryExecutionPath()
  defer {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }
  let store = try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  await store.close()
  let file = URL(fileURLWithPath: path + ".settlement-reserve")
  try FileManager.default.removeItem(at: file)
  let original = Data("synthetic-unowned-reserve-content".utf8)
  try original.write(to: file)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  await #expect(throws: ExecutionError.storageUnavailable) {
    try await SQLiteExecutionStore.open(path: path, limits: syntheticLimits)
  }
  #expect(try Data(contentsOf: file) == original)
}
