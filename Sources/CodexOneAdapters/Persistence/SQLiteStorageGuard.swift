import CSQLite
import CodexOneCore
import Foundation
import Synchronization

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Actual local volume evidence. Unknown capacity must never enable admission.
enum StorageCapacity {
  static func available(_ directory: String) throws -> Int64 {
    var info = statvfs()
    guard statvfs(directory, &info) == 0, info.f_frsize > 0 else {
      throw ExecutionError.storagePressure
    }
    let product = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_frsize))
    guard !product.overflow, product.partialValue <= UInt64(Int64.max) else {
      throw ExecutionError.storagePressure
    }
    return Int64(product.partialValue)
  }
  static func require(_ directory: String, additionalBytes: Int64, optional: Bool = false) throws {
    guard additionalBytes >= 0, additionalBytes <= 1_099_511_627_776,
      try available(directory)
        >= (optional
          ? StorageSpacePolicy.standard.optionalBytes : StorageSpacePolicy.standard.stopBytes)
        + additionalBytes
    else { throw ExecutionError.storagePressure }
  }
}

/// Mutable disk operations stay on the primary writer queue. Only the cached view crosses queues.
final class SQLiteStorageGuard: @unchecked Sendable {
  private static let magic = Data("CodexOneSettlementReserveV1\n".utf8)
  let policy: StorageSpacePolicy
  private let directory: String
  private let path: String
  private var fd: Int32
  private let available: @Sendable (String) throws -> Int64
  private let view = Mutex(StorageObservation())
  var snapshot: StorageObservation { view.withLock { $0 } }
  init(
    path: String, policy: StorageSpacePolicy,
    available: @escaping @Sendable (String) throws -> Int64 = StorageCapacity.available
  ) throws {
    self.path = path
    self.directory = (path as NSString).deletingLastPathComponent
    self.policy = policy
    self.available = available
    fd = open(
      path + ".settlement-reserve", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
      mode_t(0o600))
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    do {
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
        info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0,
        info.st_size <= policy.reserveBytes
      else { throw ExecutionError.storageUnavailable }
      if info.st_size > 0 {
        let length = Int(min(Int64(Self.magic.count), Int64(info.st_size)))
        var prefix = Data(count: length)
        let read = prefix.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, length, 0) }
        guard read == length, prefix == Self.magic.prefix(length) else {
          throw ExecutionError.storageUnavailable
        }
      }
      // Reject an existing sparse substitute; physical allocation is part of the reserve contract.
      guard Int64(info.st_blocks) * 512 >= info.st_size else {
        throw ExecutionError.storageUnavailable
      }
      let parent = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard parent >= 0 else { throw ExecutionError.storageUnavailable }
      defer { close(parent) }
      guard fsync(parent) == 0 else { throw ExecutionError.storageUnavailable }
    } catch {
      shutdown()
      throw error
    }
  }
  func shutdown() {
    if fd >= 0 {
      close(fd)
      fd = -1
    }
  }
  deinit { shutdown() }
  private func bytes(_ file: String, allowMissing: Bool = false) throws -> Int64 {
    var info = stat()
    if lstat(file, &info) != 0 {
      if allowMissing && errno == ENOENT { return 0 }
      throw ExecutionError.storagePressure
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw ExecutionError.storagePressure }
    return Int64(info.st_size)
  }
  private func reserveSize() throws -> Int64 {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_nlink == 1,
      Int64(info.st_blocks) * 512 >= info.st_size
    else { throw ExecutionError.storageUnavailable }
    return Int64(info.st_size)
  }
  private func replenish() throws {
    let size = try reserveSize()
    let missing = policy.reserveBytes - size
    guard missing > 0 else { return }
    guard (try? available(directory)).map({ $0 >= policy.resumeBytes + missing }) == true else {
      return
    }
    let zeros = Data(repeating: 0, count: 1_048_576)
    var offset = size
    while offset < policy.reserveBytes {
      var chunk = zeros
      let count = Int(min(Int64(chunk.count), policy.reserveBytes - offset))
      if offset < Self.magic.count {
        let prefixCount = min(count, Self.magic.count - Int(offset))
        chunk.replaceSubrange(
          0..<prefixCount, with: Self.magic[Int(offset)..<(Int(offset) + prefixCount)])
      }
      let wrote = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress!, count, off_t(offset)) }
      guard wrote > 0 else {
        // Preserve the physically written prefix, never claim an unallocated reserve.
        _ = fsync(fd)
        return
      }
      offset += Int64(wrote)
    }
    guard fsync(fd) == 0 else { throw ExecutionError.storageUnavailable }
    _ = try reserveSize()
  }
  func prepare(_ db: SQLiteConnection, admission: Bool, optional: Bool, essential: Bool) throws {
    try refresh(db, maintenance: false)
    if essential, (snapshot.availableBytes ?? 0) < policy.stopBytes {
      let size = try reserveSize()
      if size > 0 {
        guard ftruncate(fd, off_t(max(0, size - 8 * 1024 * 1024))) == 0, fsync(fd) == 0 else {
          throw ExecutionError.storageUnavailable
        }
        try refresh(db, maintenance: false)
      }
    }
    if admission && !snapshot.admissionAllowed { throw ExecutionError.storagePressure }
    if optional && !snapshot.optionalWorkAllowed { throw ExecutionError.storagePressure }
  }
  func refresh(_ db: SQLiteConnection, maintenance: Bool) throws {
    var next = snapshot
    if maintenance, (try? available(directory)).map({ $0 >= policy.stopBytes }) == true {
      // Zero busy wait: a long reader must not delay critical finalization work.
      guard sqlite3_busy_timeout(db.handle, 0) == SQLITE_OK else {
        throw ExecutionError.storageUnavailable
      }
      var log: Int32 = 0
      var done: Int32 = 0
      let rc = sqlite3_wal_checkpoint_v2(db.handle, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &done)
      if rc == SQLITE_OK && log == done && log > 0 {
        let truncate = sqlite3_wal_checkpoint_v2(
          db.handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        next.checkpointBusy = truncate == SQLITE_BUSY
        if truncate != SQLITE_OK && truncate != SQLITE_BUSY {
          _ = sqlite3_busy_timeout(db.handle, 250)
          throw ExecutionError.storageUnavailable
        }
      } else {
        next.checkpointBusy = rc == SQLITE_BUSY || log > done
      }
      guard sqlite3_busy_timeout(db.handle, 250) == SQLITE_OK, rc == SQLITE_OK || rc == SQLITE_BUSY
      else { throw ExecutionError.storageUnavailable }
      next.checkpointLogFrames = log
      next.checkpointedFrames = done
    }
    if maintenance { try replenish() }
    next.availableBytes = try? available(directory)
    do {
      next.databaseBytes = try bytes(path)
      next.walBytes = try bytes(path + "-wal", allowMissing: true)
    } catch { next.availableBytes = nil }
    next.reserveBytes = try reserveSize()
    next.reserveTargetBytes = policy.reserveBytes
    next.pressure = policy.pressure(
      availableBytes: next.availableBytes, reserveBytes: next.reserveBytes,
      walBytes: next.walBytes, previous: next.pressure)
    next.sampledUnixSeconds = Int64(Date().timeIntervalSince1970)
    if maintenance {
      var usage = rusage()
      #if canImport(Darwin)
        if getrusage(RUSAGE_SELF, &usage) == 0 { next.peakResidentBytes = Int64(usage.ru_maxrss) }
      #else
        if getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0 {
          next.peakResidentBytes = Int64(usage.ru_maxrss) * 1024
        }
      #endif
      next.observedFDs = (0..<next.fdScanLimit).reduce(0) {
        $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0)
      }
    }
    view.withLock { $0 = next }
  }
}
