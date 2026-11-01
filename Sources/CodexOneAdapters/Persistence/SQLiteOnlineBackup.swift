import CodexOneCore
import Dispatch
import Foundation
import Synchronization

/// Runs on a utility queue, with its own read-only WAL connection. The primary retains the flock.
public final class SQLiteOnlineBackup: BackupMaintaining, Sendable {
  public static let retainedBundles = 7
  private let primary: SQLiteExecutionStore
  private let directory: String
  private let protection: AccountCredentialCipher?
  private let state = Mutex((observation: BackupObservation(), active: false, cancelled: false))
  // Internal fault seams exercise real copy/publication/retention ordering without filling a host disk.
  private let beforeCopy: @Sendable () throws -> Void
  private let beforeStep: @Sendable () throws -> Void
  private let beforeVerify: @Sendable (String) throws -> Void

  init(
    primary: SQLiteExecutionStore, directory: String, protection: AccountCredentialCipher?,
    beforeCopy: @escaping @Sendable () throws -> Void = {},
    beforeStep: @escaping @Sendable () throws -> Void = {},
    beforeVerify: @escaping @Sendable (String) throws -> Void = { _ in }
  ) throws {
    try SQLiteSnapshotMaintenance.validateBackupDirectory(directory)
    self.primary = primary
    self.directory = directory
    self.protection = protection
    self.beforeCopy = beforeCopy
    self.beforeVerify = beforeVerify
    self.beforeStep = beforeStep
    state.withLock {
      $0.observation.enabled = true
      $0.observation.enabledUnixSeconds = primary.clock.unixSeconds
    }
    do { try refreshInventory() } catch {
      state.withLock {
        $0.observation.lastFailureUnixSeconds = primary.clock.unixSeconds
        $0.observation.lastFailure = .verificationFailed
      }
    }
  }
  public var backupObservation: BackupObservation { state.withLock { $0.observation } }
  public func cancelBackup() { state.withLock { $0.cancelled = true } }
  public func performBackup() async {
    guard
      state.withLock({ value in
        guard !value.active, !value.cancelled else { return false }
        value.active = true
        return true
      })
    else { return }
    defer { state.withLock { $0.active = false } }
    await withTaskCancellationHandler {
      _ = try? await SQLiteSnapshotMaintenance.run { self.perform() }
    } onCancel: {
      self.cancelBackup()
    }
  }
  private struct Skipped: Error { let pressure: StoragePressure }
  private func check() throws {
    if state.withLock({ $0.cancelled }) { throw CancellationError() }
    let storage = primary.storageObservation
    guard storage.optionalWorkAllowed else { throw Skipped(pressure: storage.pressure) }
  }
  private func perform() {
    var failure = BackupFailure.directoryUnavailable
    do {
      try check()
      try SQLiteSnapshotMaintenance.validateBackupDirectory(directory)
      let entries = try ownedEntries()
      for name in entries where name.hasSuffix(".partial") {
        try SQLiteSnapshotMaintenance.privateDirectory(directory + "/" + name)
        try FileManager.default.removeItem(atPath: directory + "/" + name)
      }
      failure = .snapshotFailed
      try beforeCopy()
      let source = try SQLiteConnection(readOnlyPath: primary.path, clock: primary.clock)
      defer { source.shutdown() }
      let name = "online-\(primary.clock.unixMicroseconds)-\(UUID().uuidString)"
      let partial = directory + "/" + name + ".partial"
      _ = try SQLiteSnapshotMaintenance.backup(
        source, destination: partial, protection: protection, online: true,
        check: {
          try self.check()
          try self.beforeStep()
        })
      failure = .verificationFailed
      try check()
      try beforeVerify(partial)
      let manifest = try SQLiteSnapshotMaintenance.verifyBackup(
        bundle: partial, protection: protection, clock: primary.clock, check: check)
      try check()
      // A final name means copy AND self-verification have completed. Old backups survive any failure above.
      try FileManager.default.moveItem(atPath: partial, toPath: directory + "/" + name)
      try SQLiteSnapshotMaintenance.syncDirectory(directory)
      state.withLock { $0.observation.lastSuccessUnixSeconds = manifest.createdUnixSeconds }
      failure = .retentionFailed
      let completed = try inventory()
      for entry in completed.dropLast(Self.retainedBundles) {
        try check()
        try FileManager.default.removeItem(atPath: directory + "/" + entry.name)
      }
      try SQLiteSnapshotMaintenance.syncDirectory(directory)
      try refreshInventory()
    } catch let skip as Skipped {
      state.withLock {
        $0.observation.lastSkippedUnixSeconds = primary.clock.unixSeconds
        $0.observation.skippedPressure = skip.pressure
      }
      try? refreshInventory()
    } catch {
      if state.withLock({ $0.cancelled }) {
        failure = .cancelled
      } else if !primary.storageObservation.optionalWorkAllowed {
        state.withLock {
          $0.observation.lastSkippedUnixSeconds = primary.clock.unixSeconds
          $0.observation.skippedPressure = primary.storageObservation.pressure
        }
        try? refreshInventory()
        return
      }
      if error is CancellationError { failure = .cancelled }
      if let error = error as? ExecutionError, error == .storagePressure {
        failure = .insufficientSpace
      }
      state.withLock {
        $0.observation.lastFailureUnixSeconds = primary.clock.unixSeconds
        $0.observation.lastFailure = failure
      }
      try? refreshInventory()
    }
  }
  private func ownedEntries() throws -> [String] {
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
    guard entries.count <= 1024 else { throw ExecutionError.capacity }
    return entries.filter { name in
      let base = name.hasSuffix(".partial") ? String(name.dropLast(8)) : name
      guard base.hasPrefix("online-"), base.count > 43 else { return false }
      return UUID(uuidString: String(base.suffix(36))) != nil
        && base.dropFirst(7).dropLast(37).allSatisfy(\.isNumber)
    }
  }
  private struct Entry {
    let name: String
    let manifest: SnapshotManifest
    let bytes: Int64
  }
  private func inventory() throws -> [Entry] {
    try ownedEntries().filter { !$0.hasSuffix(".partial") }.map { name in
      let bundle = directory + "/" + name
      try SQLiteSnapshotMaintenance.privateDirectory(bundle)
      let data = try SQLiteSnapshotMaintenance.readFile(bundle + "/manifest.json", limit: 8192)
      let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: data)
      guard manifest.format == 1, UUID(uuidString: manifest.id) != nil,
        manifest.createdUnixSeconds > 0, (1...1_073_741_824).contains(manifest.databaseBytes)
      else { throw ExecutionError.invalidCommand }
      return Entry(
        name: name, manifest: manifest, bytes: manifest.databaseBytes + Int64(data.count))
    }.sorted {
      if $0.manifest.createdUnixSeconds != $1.manifest.createdUnixSeconds {
        return $0.manifest.createdUnixSeconds < $1.manifest.createdUnixSeconds
      }
      return $0.name < $1.name
    }
  }
  private func refreshInventory() throws {
    let entries = try inventory()
    var bytes: Int64 = 0
    let scanFailed = Mutex(false)
    guard
      let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory),
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [],
        errorHandler: { _, _ in
          scanFailed.withLock { $0 = true }
          return false
        })
    else { throw ExecutionError.storageUnavailable }
    var count = 0
    for case let url as URL in enumerator {
      count += 1
      guard count <= 16384 else { throw ExecutionError.capacity }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else { throw ExecutionError.invalidCommand }
      if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
    }
    guard !scanFailed.withLock({ $0 }) else { throw ExecutionError.storageUnavailable }
    state.withLock {
      $0.observation.retainedCount = entries.count
      $0.observation.lastSuccessUnixSeconds = entries.last?.manifest.createdUnixSeconds
      $0.observation.totalBytes = bytes
      $0.observation.largestBundleBytes = entries.map(\.bytes).max() ?? 0
    }
  }
}

extension SQLiteExecutionStore {
  /// Caller must stop/await the backup owner before closing this store.
  public func makeOnlineBackup(directory: String, protection: AccountCredentialCipher?) throws
    -> SQLiteOnlineBackup
  {
    try SQLiteOnlineBackup(primary: self, directory: directory, protection: protection)
  }
}
