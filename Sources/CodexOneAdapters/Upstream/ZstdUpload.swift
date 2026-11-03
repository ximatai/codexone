import Foundation
import NIOCore
import NIOPosix
import Synchronization
import libzstd

/// Service-owned CPU bulkhead: four 5 MiB reservations, two workers, no waiting admission.
final class ZstdUploadPool: Sendable {
  let workers = NIOThreadPool(numberOfThreads: 2)
  private let state = Mutex((active: 0, stopped: false))

  init() { workers.start() }

  func reserve() -> Bool {
    state.withLock {
      guard !$0.stopped, $0.active < 4 else { return false }
      $0.active += 1
      return true
    }
  }
  func release() { state.withLock { $0.active -= 1 } }
  var active: Int { state.withLock { $0.active } }
  func shutdown() async throws {
    state.withLock { $0.stopped = true }
    try await workers.shutdownGracefully()
  }
}

/// Accessed only by one bounded worker job at a time; close awaits that job first.
final class ZstdEncoder: @unchecked Sendable {
  private let cancelled = Mutex(false)
  func cancel() { cancelled.withLock { $0 = true } }
  private var context: OpaquePointer?
  private var offset = 0
  private var ended = false
  private var output: UnsafeMutableRawPointer?

  deinit {
    close()
  }
  func close() {
    cancel()
    output?.deallocate()
    output = nil
    if let context { ZSTD_freeCCtx(context) }
    context = nil
  }
  private func check(_ result: Int) throws {
    guard ZSTD_isError(result) == 0 else {
      throw GatewayProtocolError(502, "upstream_compression_failed")
    }
  }
  func step(_ data: Data) throws -> (ByteBuffer?, Bool) {
    guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
    if ended { return (nil, true) }
    if context == nil {
      guard let created = ZSTD_createCCtx() else {
        throw GatewayProtocolError(502, "upstream_compression_failed")
      }
      context = created
      output = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)
      try check(ZSTD_CCtx_setParameter(created, ZSTD_c_compressionLevel, 3))
      try check(ZSTD_CCtx_setParameter(created, ZSTD_c_checksumFlag, 0))
      try check(ZSTD_CCtx_setParameter(created, ZSTD_c_contentSizeFlag, 0))
      try check(ZSTD_CCtx_setParameter(created, ZSTD_c_nbWorkers, 0))
    }
    return try data.withUnsafeBytes { bytes in
      let size = min(64 * 1024, data.count - offset)
      var input = ZSTD_inBuffer(src: bytes.baseAddress?.advanced(by: offset), size: size, pos: 0)
      var out = ZSTD_outBuffer(dst: output, size: 64 * 1024, pos: 0)
      let finishing = offset == data.count
      let result = ZSTD_compressStream2(
        context, &out, &input, finishing ? ZSTD_e_end : ZSTD_e_continue)
      try check(result)
      offset += input.pos
      ended = finishing && result == 0
      let buffer =
        out.pos == 0
        ? nil
        : ByteBuffer(
          bytes: UnsafeRawBufferPointer(start: output, count: out.pos))
      return (buffer, ended)
    }
  }
}

actor ZstdUpload {
  private let encoder = ZstdEncoder()
  private let pool: ZstdUploadPool
  private let data: Data
  private let progress: ExecutionProgress
  private let upload: RequestUpload
  private var job: Task<(ByteBuffer?, Bool), any Error>?
  private var stopped = false
  private var released = false
  private var ended = false

  init(data: Data, pool: ZstdUploadPool, progress: ExecutionProgress, upload: RequestUpload) {
    self.data = data
    self.pool = pool
    self.progress = progress
    self.upload = upload
  }

  func next() async throws -> ByteBuffer? {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    if ended {
      upload.sent()
      progress.requestSent()
      await close()
      return nil
    }
    while !stopped {
      try Task.checkCancellation()
      let encoder = encoder
      let data = data
      let workers = pool.workers
      let upload = upload
      let task = Task {
        try await workers.runIfActive {
          let start = ContinuousClock.now
          defer { upload.compressed(for: start.duration(to: .now)) }
          return try encoder.step(data)
        }
      }
      job = task
      let (buffer, complete) = try await task.value
      job = nil
      guard !stopped else { throw CancellationError() }
      try Task.checkCancellation()
      ended = complete
      if let buffer {
        upload.wrote(buffer.readableBytes)
        return buffer
      }
      if complete {
        upload.sent()
        progress.requestSent()
        await close()
        return nil
      }
    }
    throw CancellationError()
  }

  /// Called at upload EOF or exchange exit (immediately for rejected headers).
  func close() async {
    stopped = true
    encoder.cancel()
    if let job { _ = try? await job.value }
    guard !released else { return }
    released = true
    encoder.close()
    pool.release()
    upload.finish()
  }
}

struct ZstdUploadBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let owner: ZstdUpload
  func makeAsyncIterator() -> Iterator { Iterator(owner: owner) }
  struct Iterator: AsyncIteratorProtocol {
    let owner: ZstdUpload
    mutating func next() async throws -> ByteBuffer? { try await owner.next() }
  }
}
