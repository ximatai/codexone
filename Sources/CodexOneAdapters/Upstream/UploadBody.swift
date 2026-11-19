import Foundation
import NIOCore
import Synchronization

/// Owns the encoded bytes through transport EOF and any permitted encoding negotiation.
final class HTTPUploadPayload: Sendable {
  private struct State {
    var data: Data?
    var sent = false
    var finalEncoding = false
  }
  private let state: Mutex<State>
  private let lease: RequestBodyLease?
  let count: Int

  init(data: Data, lease: RequestBodyLease? = nil) {
    count = data.count
    state = Mutex(.init(data: data))
    self.lease = lease
  }

  func read<T>(_ operation: (Data) throws -> T) throws -> T {
    try state.withLock {
      guard let data = $0.data else { throw CancellationError() }
      return try operation(data)
    }
  }

  func sent() { update { $0.sent = true } }
  func useFinalEncoding() { update { $0.finalEncoding = true } }

  // Exchange teardown invalidates any transport iterator still holding this payload.
  // The ingress owner returns any lease that was not already released at EOF.
  func discard() { state.withLock { $0.data = nil } }

  // After the zstd producer has stopped, only EOF from the plaintext retry counts.
  func retryPlaintext() {
    state.withLock {
      $0.sent = false
      $0.finalEncoding = true
    }
  }

  private func update(_ change: (inout State) -> Void) {
    let discarded = state.withLock {
      change(&$0)
      guard $0.sent, $0.finalEncoding, $0.data != nil else { return false }
      $0.data = nil
      return true
    }
    if discarded { lease?.release() }
  }
}

/// Keeps the encoded Data and at most one bounded conversion buffer per pull.
/// AHC requests EOF after handing the final chunk to its backpressured transport.
struct UploadBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let payload: HTTPUploadPayload
  let progress: ExecutionProgress
  let upload: RequestUpload
  let trackUploadProgress: Bool

  init(
    payload: HTTPUploadPayload, progress: ExecutionProgress, upload: RequestUpload,
    trackUploadProgress: Bool = false
  ) {
    self.payload = payload
    self.progress = progress
    self.upload = upload
    self.trackUploadProgress = trackUploadProgress
  }

  func makeAsyncIterator() -> Iterator {
    Iterator(body: self, offset: 0)
  }

  struct Iterator: AsyncIteratorProtocol {
    let body: UploadBody
    var offset: Data.Index
    mutating func next() async throws -> ByteBuffer? {
      try Task.checkCancellation()
      guard offset < body.payload.count else {
        body.payload.sent()
        body.upload.sent()
        body.upload.finish()
        body.progress.requestSent()
        return nil
      }
      let end = Swift.min(offset + 64 * 1024, body.payload.count)
      let start = offset
      let buffer = try body.payload.read { data in
        ByteBuffer(bytes: data[(data.startIndex + start)..<(data.startIndex + end)])
      }
      offset = end
      body.upload.wrote(buffer.readableBytes)
      if body.trackUploadProgress { body.progress.noteUpload() }
      return buffer
    }
  }
}

/// One observation per upload, also on cancellation/failure; no content or exact sizes.
final class RequestUpload: Sendable {
  private let start = ContinuousClock.now
  private let bytes: Int
  private let transport: String
  private let encoding: String
  private let counters = Mutex((wire: 0, compression: Duration.zero))
  private let completed = Mutex<Duration?>(nil)
  private let finished = Mutex(false)

  init(bytes: Int, transport: String, encoding: String = "identity") {
    self.encoding = encoding
    self.bytes = bytes
    self.transport = transport
  }
  func wrote(_ bytes: Int) { counters.withLock { $0.wire += bytes } }
  func compressed(for duration: Duration) { counters.withLock { $0.compression += duration } }
  func sent() { completed.withLock { if $0 == nil { $0 = start.duration(to: .now) } } }
  func finish() {
    guard
      finished.withLock({ value in
        guard !value else { return false }
        value = true
        return true
      })
    else { return }
    let duration = completed.withLock { $0 }
    ProtocolFailureDiagnostics.recordUpload(
      bytes: bytes, duration: duration ?? start.duration(to: .now), transport: transport,
      sent: duration != nil, encoding: transport == "http" ? encoding : nil,
      wireBytes: counters.withLock { $0.wire },
      compression: counters.withLock { $0.compression })
  }
}
