import CSQLite
import CodexOneCore
import Crypto
import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public enum SnapshotMaintenanceError: Error { case incompleteRestore, requiresManagedKeys }

public struct SnapshotManifest: Codable, Sendable {
  public let format: Int
  public let id: String
  public let createdUnixSeconds: Int64
  public let schema: Int
  public let sourceGeneration: String
  public let databaseBytes: Int64
  public let databaseSHA256: String
  public let requiredKeyIDs: [String]
}

/// Offline commands retain the same flock as the service. They never replace a live database.
public enum SQLiteSnapshotMaintenance {
  static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try operation() })
      }
    }
  }
  public static func backup(
    path: String, destination: String, protection: AccountCredentialCipher?,
    clock: WallClock = .system
  )
    async throws -> SnapshotManifest
  {
    try await run {
      let db = try SQLiteConnection(path: path, existingOnly: true, clock: clock)
      defer { db.shutdown() }
      return try backup(db, destination: destination, protection: protection)
    }
  }
  static func backup(
    _ db: SQLiteConnection, destination: String, protection: AccountCredentialCipher?,
    online: Bool = false, check: () throws -> Void = {}
  ) throws -> SnapshotManifest {
    guard try db.reencryptionCheckpoint()?.complete != false else {
      throw KeyMaintenanceError.incompleteReencryption
    }
    let record = try db.restoreRecord()
    guard record == nil || record?.baseline != nil else { throw ExecutionError.denied }
    if !online { _ = try verifyCredentials(db, protection) }
    let snapshotBytes = try db.scalar("PRAGMA page_count") * db.scalar("PRAGMA page_size")
    try StorageCapacity.require(
      (destination as NSString).deletingLastPathComponent,
      additionalBytes: snapshotBytes + 8 * 1024 * 1024, optional: true)
    try StorageCapacity.require(
      (db.filePath as NSString).deletingLastPathComponent, additionalBytes: 8 * 1024 * 1024,
      optional: true)
    guard mkdir(destination, 0o700) == 0 else { throw ExecutionError.conflict }
    try privateDirectory(destination)
    let partial = destination + "/snapshot.sqlite.partial"
    try copy(db, to: partial, optional: true, online: online, check: check)
    try check()
    // Read metadata from the completed copy, never a later live-source revision.
    let snapshot = try SQLiteConnection(readOnlyPath: partial, clock: db.clock)
    defer { snapshot.shutdown() }
    let keys = try verifyCredentials(snapshot, protection)
    let hash = try fingerprint(partial, check: check)
    let generation = try snapshot.rows("SELECT generation FROM maintenance_state WHERE id=1") {
      String(cString: sqlite3_column_text($0, 0))
    }
    guard generation.count == 1 else { throw ExecutionError.storageUnavailable }
    let manifest = SnapshotManifest(
      format: 1, id: UUID().uuidString,
      createdUnixSeconds: db.clock.unixSeconds,
      schema: Int(try snapshot.scalar("PRAGMA user_version")),
      sourceGeneration: generation[0], databaseBytes: hash.0, databaseSHA256: hash.1,
      requiredKeyIDs: keys)
    guard rename(partial, destination + "/snapshot.sqlite") == 0 else {
      throw ExecutionError.storageUnavailable
    }
    try writeFile(destination + "/snapshot.sqlite.lock", Data())
    try writeFile(destination + "/manifest.partial", JSONEncoder().encode(manifest))
    guard rename(destination + "/manifest.partial", destination + "/manifest.json") == 0 else {
      throw ExecutionError.storageUnavailable
    }
    try syncDirectory(destination)
    try syncDirectory((destination as NSString).deletingLastPathComponent)
    return manifest
  }

  public static func restore(
    bundle: String, path: String, protection: AccountCredentialCipher?, clock: WallClock = .system
  )
    async throws -> RestoreRecord
  {
    try await restore(
      bundle: bundle, path: path, protection: protection, clock: clock, syncParent: syncDirectory)
  }

  // Internal fault seam verifies parent-directory synchronization failures before any copied page.
  static func restore(
    bundle: String, path: String, protection: AccountCredentialCipher?, clock: WallClock = .system,
    syncParent: @escaping @Sendable (String) throws -> Void
  ) async throws -> RestoreRecord {
    try await run {
      let verified = try verifiedSnapshot(bundle: bundle, protection: protection, clock: clock)
      defer {
        verified.source.shutdown()
        close(verified.lockFD)
      }
      let manifest = verified.manifest
      let source = verified.source
      let snapshot = verified.path
      let previous = try source.restoreRecord()
      guard previous == nil || previous?.baseline != nil else { throw ExecutionError.denied }
      let directory = (path as NSString).deletingLastPathComponent
      try StorageCapacity.require(
        FileManager.default.fileExists(atPath: directory)
          ? directory : (directory as NSString).deletingLastPathComponent,
        additionalBytes: manifest.databaseBytes + 8 * 1024 * 1024)
      if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw ExecutionError.storageUnavailable }
      try privateDirectory(directory)
      try syncParent((directory as NSString).deletingLastPathComponent)
      let targetLock = try lock(path + ".lock")
      defer { close(targetLock) }
      let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
      guard entries.allSatisfy({ $0 == (path as NSString).lastPathComponent + ".lock" }) else {
        throw ExecutionError.conflict
      }
      // Durable barrier precedes the first copied page. Interrupted targets fail closed.
      try writeFile(path + ".restore-pending", Data(manifest.id.utf8))
      try syncDirectory(directory)
      let staging = path + ".restoring.partial"
      try copy(source, to: staging)
      let unchangedSource = try fingerprint(snapshot)
      guard unchangedSource.0 == manifest.databaseBytes,
        unchangedSource.1 == manifest.databaseSHA256
      else { throw ExecutionError.invalidCommand }
      let target = try SQLiteConnection(
        path: staging, existingOnly: true, restoringV7: manifest.schema < 11, clock: clock)
      let completedCopyAt = clock.unixSeconds
      let record = RestoreRecord(
        id: UUID().uuidString, backupID: manifest.id,
        snapshotUnixSeconds: manifest.createdUnixSeconds, restoredUnixSeconds: completedCopyAt,
        inheritedUnresolvedRequests: previous?.unresolvedRequests ?? 0,
        inheritedUnresolvedMicros: previous?.unresolvedMicros ?? 0,
        inheritedFreezeUntilUnixSeconds: previous?.baseline?.freezeUntilUnixSeconds ?? 0)
      do {
        try target.transaction {
          try target.write(
            "UPDATE maintenance_state SET generation=?,restore_json=? WHERE id=1",
            [
              .text(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
              .text(try encode(record)),
            ])
          try target.write(
            "UPDATE attempts SET state='unknown',unknown_since_epoch=? WHERE state='intent'",
            [.number(clock.unixSeconds)]
          )
          // Old context and revocations after the snapshot cannot be reconstructed.
          try target.write("DELETE FROM bindings")
          try target.write("UPDATE accounts SET authorization='requires_auth',refresh_intent=NULL")
          // Preserve unknown redemption IDs; restored automation requires explicit opt-in.
          try target.write(
            "UPDATE account_reset_credits SET record_json=json_set(record_json,'$.settings.autoUseBeforeExpiry',json('false'))"
          )
          let keys = try target.rows("SELECT id,metadata_json FROM managed_keys LIMIT 257") { row in
            guard sqlite3_column_bytes(row, 0) <= 64, sqlite3_column_bytes(row, 1) <= 16384 else {
              throw ExecutionError.capacity
            }
            let key = try JSONDecoder().decode(
              ManagedKey.self, from: Data(String(cString: sqlite3_column_text(row, 1)).utf8))
            guard key.id == String(cString: sqlite3_column_text(row, 0)),
              (1..<1_000_000).contains(key.revision), (1...64).contains(key.principal.utf8.count)
            else { throw ExecutionError.invalidCommand }
            return key
          }
          guard keys.count <= 256 else { throw ExecutionError.capacity }
          for key in keys {
            guard key.revision < 1_000_000 else { throw ExecutionError.capacity }
            let disabled = ManagedKey(
              id: key.id, principal: key.principal, revision: key.revision + 1,
              enabled: false, policy: key.policy, createdAtUnixSeconds: key.createdAtUnixSeconds,
              expiresAtUnixSeconds: key.expiresAtUnixSeconds, displayName: key.displayName,
              archivedAtUnixSeconds: key.archivedAtUnixSeconds)
            let digest = SHA256.hash(data: Data(UUID().uuidString.utf8)).map {
              String(format: "%02x", $0)
            }.joined()
            try target.write(
              "UPDATE managed_keys SET digest=?,metadata_json=? WHERE id=?",
              [.text(digest), .text(try encode(disabled)), .text(key.id)])
          }
          try audit(
            target, action: "restored_unreconciled", record: encode(record), at: completedCopyAt)
        }
        try target.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        target.shutdown()
      } catch {
        target.shutdown()
        throw error
      }
      try syncFile(staging)
      guard rename(staging, path) == 0 else { throw ExecutionError.storageUnavailable }
      try syncDirectory(directory)
      guard unlink(path + ".restore-pending") == 0 else { throw ExecutionError.storageUnavailable }
      try syncDirectory(directory)
      return record
    }
  }

  private struct VerifiedSnapshot {
    let manifest: SnapshotManifest
    let source: SQLiteConnection
    let lockFD: Int32
    let path: String
  }
  private static func verifiedSnapshot(
    bundle: String, protection: AccountCredentialCipher?, clock: WallClock,
    check: @escaping @Sendable () throws -> Void = {}
  ) throws
    -> VerifiedSnapshot
  {
    try privateDirectory(bundle)
    let manifest: SnapshotManifest = try JSONDecoder().decode(
      SnapshotManifest.self, from: readFile(bundle + "/manifest.json", limit: 8192))
    let now = clock.unixSeconds
    guard manifest.format == 1, [7, 8, 9, 10, 11].contains(manifest.schema),
      UUID(uuidString: manifest.id) != nil,
      manifest.createdUnixSeconds > 0, manifest.createdUnixSeconds <= now,
      manifest.sourceGeneration.count == 32, manifest.requiredKeyIDs.count <= 64,
      (1...1_073_741_824).contains(manifest.databaseBytes),
      manifest.databaseSHA256.count == 64
    else { throw ExecutionError.invalidCommand }
    let snapshot = bundle + "/snapshot.sqlite"
    for suffix in ["-wal", "-shm", ".restore-pending"] {
      guard !FileManager.default.fileExists(atPath: snapshot + suffix) else {
        throw ExecutionError.invalidCommand
      }
    }
    let sourceLock = try lock(snapshot + ".lock", readOnly: true)
    do {
      let actual = try fingerprint(snapshot, check: check)
      guard actual.0 == manifest.databaseBytes, actual.1 == manifest.databaseSHA256 else {
        throw ExecutionError.invalidCommand
      }
      let source = try SQLiteConnection(readOnlyPath: snapshot, clock: clock)
      let budget = SnapshotReadCheck(check: check)
      sqlite3_progress_handler(
        source.handle, 1000,
        { pointer in
          guard let pointer else { return 1 }
          let budget = Unmanaged<SnapshotReadCheck>.fromOpaque(pointer).takeUnretainedValue()
          return budget.shouldStop ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
      defer { sqlite3_progress_handler(source.handle, 0, nil, nil) }
      try check()
      guard try source.scalar("PRAGMA user_version") == Int64(manifest.schema),
        try verifyCredentials(source, protection) == manifest.requiredKeyIDs,
        try source.rows("PRAGMA quick_check", map: { String(cString: sqlite3_column_text($0, 0)) })
          == ["ok"],
        try source.scalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0
      else { throw ExecutionError.invalidCommand }
      guard
        try source.rows(
          "SELECT generation FROM maintenance_state WHERE id=1",
          map: { String(cString: sqlite3_column_text($0, 0)) }) == [manifest.sourceGeneration]
      else { throw ExecutionError.invalidCommand }
      guard try source.reencryptionCheckpoint()?.complete != false else {
        throw KeyMaintenanceError.incompleteReencryption
      }
      return VerifiedSnapshot(
        manifest: manifest, source: source, lockFD: sourceLock, path: snapshot)
    } catch {
      close(sourceLock)
      throw error
    }
  }
  public static func verifyBackup(
    bundle: String, protection: AccountCredentialCipher?, clock: WallClock = .system
  ) async throws
    -> SnapshotManifest
  {
    try await run { try verifyBackup(bundle: bundle, protection: protection, clock: clock) }
  }
  static func verifyBackup(
    bundle: String, protection: AccountCredentialCipher?, clock: WallClock = .system,
    check: @escaping @Sendable () throws -> Void = {}
  ) throws -> SnapshotManifest {
    let verified = try verifiedSnapshot(
      bundle: bundle, protection: protection, clock: clock, check: check)
    defer {
      verified.source.shutdown()
      close(verified.lockFD)
    }
    return verified.manifest
  }

  public static func status(path: String, clock: WallClock = .system) async throws -> RestoreRecord?
  {
    try await run {
      let db = try SQLiteConnection(path: path, existingOnly: true, clock: clock)
      defer { db.shutdown() }
      return try db.restoreRecord()
    }
  }
  public static func reconcileFile(path: String, baselineFile: String, clock: WallClock = .system)
    async throws -> RestoreRecord
  {
    let baseline = try await run {
      try JSONDecoder().decode(RestoreBaseline.self, from: readFile(baselineFile, limit: 8192))
    }
    return try await reconcile(path: path, baseline: baseline, clock: clock)
  }
  public static func reconcile(path: String, baseline: RestoreBaseline, clock: WallClock = .system)
    async throws
    -> RestoreRecord
  {
    try baseline.validate()
    return try await run {
      let db = try SQLiteConnection(path: path, existingOnly: true, clock: clock)
      defer { db.shutdown() }
      return try db.transaction {
        guard let current = try db.restoreRecord() else { throw ExecutionError.conflict }
        let record = try current.reconciling(baseline, at: clock.unixSeconds)
        if record == current { return current }
        try db.write(
          "UPDATE maintenance_state SET restore_json=? WHERE id=1", [.text(try encode(record))])
        try audit(
          db, action: "baseline_attested_old_windows_frozen", record: encode(record),
          at: record.reconciledUnixSeconds!)
        return record
      }
    }
  }

  static func audit(_ db: SQLiteConnection, action: String, record: String, at: Int64)
    throws
  {
    guard
      try action == "credential_reencryption" || (db.reencryptionCheckpoint()?.complete != false)
    else { throw KeyMaintenanceError.incompleteReencryption }
    guard
      try action == "release_unknown"
        || (db.scalar("SELECT COUNT(*) FROM maintenance_events WHERE action!='release_unknown'")
          < 1000)
    else {
      throw ExecutionError.capacity
    }
    try db.write(
      "INSERT INTO maintenance_events(action,record_json,at_epoch) VALUES(?,?,?)",
      [.text(action), .text(record), .number(at)])
  }
  private static func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  static func verifyCredentials(
    _ db: SQLiteConnection, _ protection: AccountCredentialCipher?
  ) throws -> [String] {
    let rows = try db.rows(
      "SELECT id,namespace,credential_version,sealed_credential FROM accounts LIMIT 65"
    ) { row in
      guard sqlite3_column_bytes(row, 0) <= 64, sqlite3_column_bytes(row, 1) <= 512,
        sqlite3_column_bytes(row, 3) <= 49_152
      else { throw ExecutionError.capacity }
      return (
        String(cString: sqlite3_column_text(row, 0)), String(cString: sqlite3_column_text(row, 1)),
        sqlite3_column_int64(row, 2), String(cString: sqlite3_column_text(row, 3))
      )
    }
    guard rows.count <= 64 else { throw ExecutionError.capacity }
    if rows.isEmpty { return [] }
    guard let protection else { throw ExecutionError.unauthorized }
    var required = Set<String>()
    for row in rows {
      required.insert(try AccountCredentialCipher.envelopeKeyID(row.3))
      _ = try protection.open(
        row.3, context: .init(identity: row.0, namespace: row.1, version: row.2))
    }
    return required.sorted()
  }
  private static func copy(
    _ source: SQLiteConnection, to path: String, optional: Bool = false, online: Bool = false,
    check: () throws -> Void = {}
  ) throws {
    let pageSize = try source.scalar("PRAGMA page_size")
    let pages = try source.scalar("PRAGMA page_count")
    guard pageSize > 0, pages <= 1_073_741_824 / pageSize else { throw ExecutionError.capacity }
    try StorageCapacity.require(
      (path as NSString).deletingLastPathComponent,
      additionalBytes: pages * pageSize + 8 * 1024 * 1024, optional: optional)
    let fd = try newFile(path)
    defer { close(fd) }
    var target: OpaquePointer?
    guard let resolved = path.withCString({ realpath($0, nil) }) else {
      throw ExecutionError.storageUnavailable
    }
    let canonical = String(cString: resolved)
    free(resolved)
    let opened = sqlite3_open_v2(
      canonical, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
    guard opened == SQLITE_OK, let target else {
      if let target { sqlite3_close_v2(target) }
      throw ExecutionError.storageUnavailable
    }
    defer { sqlite3_close_v2(target) }
    guard let transfer = sqlite3_backup_init(target, "main", source.handle, "main") else {
      throw ExecutionError.storageUnavailable
    }
    var finished = false
    defer { if !finished { sqlite3_backup_finish(transfer) } }
    var step: Int32
    let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000_000
    repeat {
      try check()
      guard !online || DispatchTime.now().uptimeNanoseconds < deadline else {
        throw ExecutionError.storageUnavailable
      }
      try StorageCapacity.require(
        (path as NSString).deletingLastPathComponent, additionalBytes: 2 * 1024 * 1024,
        optional: optional)
      step = sqlite3_backup_step(transfer, 128)
      guard Int64(sqlite3_backup_pagecount(transfer)) <= 1_073_741_824 / pageSize else {
        throw ExecutionError.capacity
      }
      if online && (step == SQLITE_OK || step == SQLITE_BUSY || step == SQLITE_LOCKED) {
        // Release the SQLite read lock between steps; do not pin a read transaction/WAL.
        usleep(step == SQLITE_OK ? 1_000 : 10_000)
      }
    } while step == SQLITE_OK || (online && (step == SQLITE_BUSY || step == SQLITE_LOCKED))
    let finish = sqlite3_backup_finish(transfer)
    finished = true
    guard step == SQLITE_DONE, finish == SQLITE_OK,
      sqlite3_exec(target, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;", nil, nil, nil)
        == SQLITE_OK,
      fsync(fd) == 0
    else { throw ExecutionError.storageUnavailable }
  }
  private static func newFile(_ path: String) throws -> Int32 {
    let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    return fd
  }
  private static func lock(_ path: String, readOnly: Bool = false) throws -> Int32 {
    let fd = open(
      path, (readOnly ? O_RDONLY : O_RDWR | O_CREAT) | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    do {
      try validateFile(fd)
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ExecutionError.instanceLocked }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }
  private static func validateFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_nlink == 1, info.st_mode & 0o077 == 0
    else { throw ExecutionError.invalidCommand }
  }
  static func privateDirectory(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
      info.st_mode & 0o077 == 0
    else { throw ExecutionError.invalidCommand }
  }
  public static func validateBackupDirectory(_ path: String) throws {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ExecutionError.invalidCommand }
    try privateDirectory(path)
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & 0o700 == 0o700, access(path, W_OK | X_OK) == 0
    else { throw ExecutionError.invalidCommand }
  }
  static func readFile(_ path: String, limit: Int) throws -> Data {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ExecutionError.invalidCommand }
    defer { close(fd) }
    try validateFile(fd)
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw ExecutionError.capacity }
    return data
  }
  private static func writeFile(_ path: String, _ data: Data) throws {
    let fd = try newFile(path)
    defer { close(fd) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    try file.write(contentsOf: data)
    guard fsync(fd) == 0 else { throw ExecutionError.storageUnavailable }
  }
  static func fingerprint(_ path: String, check: () throws -> Void = {}) throws -> (Int64, String) {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ExecutionError.invalidCommand }
    defer { close(fd) }
    try validateFile(fd)
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var bytes: Int64 = 0
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
      try check()
      bytes += Int64(chunk.count)
      guard bytes <= 1_073_741_824 else { throw ExecutionError.capacity }
      hash.update(data: chunk)
    }
    return (bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  private static func syncFile(_ path: String) throws {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw ExecutionError.storageUnavailable }
  }
  static func syncDirectory(_ path: String) throws {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw ExecutionError.storageUnavailable }
  }
}

extension SQLiteConnection {
  func restoreRecord() throws -> RestoreRecord? {
    let rows = try rows("SELECT restore_json FROM maintenance_state WHERE id=1") {
      row -> RestoreRecord? in
      guard sqlite3_column_type(row, 0) != SQLITE_NULL else { return nil }
      guard sqlite3_column_bytes(row, 0) <= 16384 else { throw ExecutionError.capacity }
      let record = try JSONDecoder().decode(
        RestoreRecord.self, from: Data(String(cString: sqlite3_column_text(row, 0)).utf8))
      try record.validate()
      return record
    }
    guard rows.count == 1 else { throw ExecutionError.storageUnavailable }
    return rows[0]
  }
}

/// The closure is called only on the snapshot utility worker, including SQLite's progress callback.
private final class SnapshotReadCheck {
  private let check: @Sendable () throws -> Void
  init(check: @escaping @Sendable () throws -> Void) { self.check = check }
  var shouldStop: Bool {
    do {
      try check()
      return false
    } catch { return true }
  }
}
