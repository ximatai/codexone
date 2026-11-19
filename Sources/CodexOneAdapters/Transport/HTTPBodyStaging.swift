import CodexOneCore
import Crypto
import Foundation
import NIOPosix
import Synchronization

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Separate capacity for encrypted bodies. The data service joins every user before shutting down I/O.
final class HTTPBodyStaging: Sendable {
  static let capacity = 192 * 1024 * 1024
  let workers = NIOThreadPool(numberOfThreads: 2)
  private let directory: String
  private let budget: RequestBodyBudget

  init(directory: String, capacity: Int = HTTPBodyStaging.capacity) {
    self.directory = directory
    budget = RequestBodyBudget(capacity: capacity, headroomCapacity: 0)
    workers.start()
  }

  func begin(length: Int) async throws -> StagedHTTPBody {
    try Task.checkCancellation()
    let lease = budget.lease()
    try lease.reserve(EncryptedHTTPBody.diskBytes(length))
    let file = try await workers.runIfActive { [directory, capacity = budget.capacity] in
      try StorageCapacity.require(directory, additionalBytes: Int64(capacity), optional: true)
      return try EncryptedHTTPBody(directory: directory, length: length)
    }
    return StagedHTTPBody(staging: self, file: file, lease: lease)
  }

  func encode(_ document: PendingHTTPBody<JSONValue>, lease: RequestBodyLease) async throws
    -> HTTPUploadPayload
  {
    let file = try await workers.runIfActive {
      [directory, capacity = budget.capacity] in
      let data = try document.take().data()
      try lease.reserve(EncryptedHTTPBody.diskBytes(data.count))
      try StorageCapacity.require(directory, additionalBytes: Int64(capacity), optional: true)
      let file = try EncryptedHTTPBody(directory: directory, length: data.count)
      try file.append(data)
      try file.seal()
      return file
    }
    return HTTPUploadPayload(file: file, workers: workers, lease: lease)
  }
}

struct StagedHTTPBody: Sendable {
  let staging: HTTPBodyStaging
  let file: EncryptedHTTPBody
  let lease: RequestBodyLease

  func append(_ bytes: Data) async throws {
    try Task.checkCancellation()
    try await staging.workers.runIfActive { try file.append(bytes) }
  }

  func decodeInput() async throws -> Data {
    try await staging.workers.runIfActive {
      defer { file.discard() }
      try file.seal()
      return try file.decodeInput()
    }
  }

  func discard() {
    file.discard()
    lease.release()
  }
}

/// The pathname never contains content or survives the open. The index is authenticated with each
/// record so reads and retries can use independent cursors without exposing plaintext to the disk.
final class EncryptedHTTPBody: Sendable {
  static let block = 64 * 1024
  private static let overhead = 28  // AES-GCM combined nonce and tag.
  private struct State {
    var file: FileHandle?
    var key: SymmetricKey? = SymmetricKey(size: .bits256)
    var pending = Data()
    var committed = 0
    var sealed = false
  }
  private let state: Mutex<State>
  let length: Int

  static func diskBytes(_ length: Int) -> Int {
    length + ((length + block - 1) / block) * overhead
  }

  init(directory: String, length: Int) throws {
    self.length = length
    var name = Array((directory + "/.responses-upload.XXXXXX").utf8CString)
    let fd = name.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    guard fd >= 0 else { throw ExecutionError.storageUnavailable }
    guard name.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0,
      fcntl(fd, F_SETFD, FD_CLOEXEC) != -1
    else {
      _ = close(fd)
      throw ExecutionError.storageUnavailable
    }
    state = Mutex(.init(file: FileHandle(fileDescriptor: fd, closeOnDealloc: true)))
  }

  func append(_ bytes: Data) throws {
    try state.withLock { value in
      guard !value.sealed, let file = value.file,
        bytes.count <= length - value.committed - value.pending.count
      else { throw GatewayProtocolError(400, "invalid_request") }
      var position = bytes.startIndex
      while position < bytes.endIndex {
        let end = min(bytes.endIndex, position + Self.block - value.pending.count)
        value.pending.append(contentsOf: bytes[position..<end])
        position = end
        if value.pending.count == Self.block { try writeBlock(&value, file: file) }
      }
    }
  }

  func seal() throws {
    try state.withLock { value in
      guard let file = value.file, value.committed + value.pending.count == length else {
        throw GatewayProtocolError(400, "invalid_request")
      }
      if !value.pending.isEmpty { try writeBlock(&value, file: file) }
      value.sealed = true
    }
  }

  func discard() {
    state.withLock { value in
      try? value.file?.close()
      value.file = nil
      value.key = nil
      value.pending = Data()
    }
  }

  func chunk(at offset: Int) throws -> Data {
    try state.withLock { value in
      guard value.sealed, let file = value.file, let key = value.key, offset >= 0, offset < length
      else {
        throw CancellationError()
      }
      let block = offset / Self.block
      let blockStart = block * Self.block
      let size = min(Self.block, length - blockStart) + Self.overhead
      do {
        try file.seek(toOffset: UInt64(blockStart + block * Self.overhead))
        guard let encrypted = try file.read(upToCount: size), encrypted.count == size else {
          throw ExecutionError.storageUnavailable
        }
        let plaintext = try AES.GCM.open(
          AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: index(block))
        return plaintext.dropFirst(offset - blockStart)
      } catch { throw ExecutionError.storageUnavailable }
    }
  }

  func decodeInput() throws -> Data {
    var data = Data(capacity: length)
    while data.count < length { data.append(try chunk(at: data.count)) }
    return data
  }

  private func writeBlock(_ value: inout State, file: FileHandle) throws {
    do {
      guard let key = value.key else { throw ExecutionError.storageUnavailable }
      let sealed = try AES.GCM.seal(
        value.pending, using: key, authenticating: index(value.committed / Self.block))
      guard let combined = sealed.combined else { throw ExecutionError.storageUnavailable }
      try file.write(contentsOf: combined)
      value.committed += value.pending.count
      value.pending.removeAll(keepingCapacity: true)
    } catch { throw ExecutionError.storageUnavailable }
  }

  private func index(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) }
  }
}
