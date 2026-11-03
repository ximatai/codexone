import Foundation
import NIOCore
import Synchronization

/// Keeps the encoded Data and at most one bounded conversion buffer per pull.
/// AHC requests EOF after handing the final chunk to its backpressured transport.
struct UploadBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let data: Data
  let progress: ExecutionProgress
  let upload: RequestUpload

  func makeAsyncIterator() -> Iterator {
    Iterator(body: self, offset: data.startIndex)
  }

  struct Iterator: AsyncIteratorProtocol {
    let body: UploadBody
    var offset: Data.Index
    mutating func next() async throws -> ByteBuffer? {
      try Task.checkCancellation()
      guard offset < body.data.endIndex else {
        body.upload.sent()
        body.progress.requestSent()
        return nil
      }
      let end = Swift.min(offset + 64 * 1024, body.data.endIndex)
      let buffer = ByteBuffer(bytes: body.data[offset..<end])
      offset = end
      return buffer
    }
  }
}

/// One observation per upload, also on cancellation/failure; no content or exact sizes.
final class RequestUpload: Sendable {
  private let start = ContinuousClock.now
  private let bytes: Int
  private let transport: String
  private let completed = Mutex<Duration?>(nil)
  private let finished = Mutex(false)

  init(bytes: Int, transport: String) {
    self.bytes = bytes
    self.transport = transport
  }
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
      sent: duration != nil)
  }
}
