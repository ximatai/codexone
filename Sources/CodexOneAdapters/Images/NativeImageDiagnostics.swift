import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import Synchronization

/// One constant-size observation per dispatched native image attempt; never retains wire data.
final class NativeImageDiagnostics: Sendable {
  private struct State {
    var headers: ContinuousClock.Instant?
    var firstBody: ContinuousClock.Instant?
    var lastBody: ContinuousClock.Instant?
    var longestGap: Duration = .zero
    var bytes = 0
    var status: Int?
    var contentType: String?
    var bodyError: String?
  }
  private static let logger = Logger(label: "codexone.protocol")
  private static let gate = Mutex(ProtocolFailureLogGate())
  private let state = Mutex(State())
  private let now: @Sendable () -> ContinuousClock.Instant
  private let dispatched: ContinuousClock.Instant
  private let streaming: Bool

  init(streaming: Bool, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
    self.streaming = streaming
    self.now = now
    dispatched = now()
  }

  func receivedHeaders(status: Int, contentType: String? = nil) {
    let instant = now()
    state.withLock {
      $0.headers = instant
      $0.status = status
      $0.contentType = Self.contentTypeToken(contentType)
    }
  }

  static func contentTypeToken(_ value: String?) -> String {
    guard let value else { return "missing" }
    guard value.utf8.count <= 256 else { return "other" }
    let media =
      (value.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
      .trimmingCharacters(in: .whitespaces)
    switch media {
    case "application/json": return "json"
    case "text/event-stream": return "sse"
    case "text/html": return "html"
    case "text/plain": return "text"
    case "application/octet-stream": return "binary"
    default: return "other"
    }
  }

  func receivedBody(bytes: Int) {
    guard bytes > 0 else { return }
    let instant = now()
    state.withLock {
      if let previous = $0.lastBody ?? $0.headers {
        $0.longestGap = max($0.longestGap, previous.duration(to: instant))
      }
      if $0.firstBody == nil { $0.firstBody = instant }
      $0.lastBody = instant
      $0.bytes += min(bytes, Int.max - $0.bytes)
    }
  }

  // ProviderError deliberately swallows body-read errors. Retain only their safe classification.
  func bodyFailed(_ error: any Error) {
    state.withLock { $0.bodyError = Self.errorToken(error) }
  }

  static func errorToken(_ error: (any Error)?) -> String {
    guard let error else { return "none" }
    if error is CancellationError { return "cancelled" }
    if let error = error as? HTTPClientError {
      let known: [(HTTPClientError, String)] = [
        (.remoteConnectionClosed, "remoteConnectionClosed"), (.readTimeout, "readTimeout"),
        (.writeTimeout, "writeTimeout"), (.connectTimeout, "connectTimeout"),
        (.deadlineExceeded, "deadlineExceeded"), (.cancelled, "cancelled"),
        (.tlsHandshakeTimeout, "tlsHandshakeTimeout"),
        (.httpProxyHandshakeTimeout, "httpProxyHandshakeTimeout"),
        (.socksHandshakeTimeout, "socksHandshakeTimeout"),
        (.getConnectionFromPoolTimeout, "getConnectionFromPoolTimeout"),
        (.uncleanShutdown, "uncleanShutdown"), (.bodyLengthMismatch, "bodyLengthMismatch"),
        (.requestStreamCancelled, "cancelled"),
      ]
      return known.first(where: { $0.0 == error })?.1 ?? "other"
    }
    #if !os(Windows)
      if let error = error as? IOError, (0...4095).contains(error.errnoCode) {
        return "io_errno_\(error.errnoCode)"
      }
    #endif
    if let error = error as? GatewayProtocolError {
      let known: Set<String> = [
        "execution_indeterminate", "execution_deadline_exceeded",
        "execution_first_response_timeout", "execution_progress_timeout",
        "invalid_upstream_content_type", "invalid_upstream_image", "invalid_upstream_response",
        "invalid_upstream_event", "incomplete_upstream_event", "upstream_event_too_large",
        "upstream_response_too_large",
        "upstream_rejected", "upstream_unavailable", "upstream_authentication_rejected",
        "upstream_rate_limited", "upstream_execution_failed",
      ]
      return known.contains(error.code) ? "gateway_" + error.code : "other"
    }
    return "other"
  }

  func metadata(error: (any Error)?, requestID: String) -> Logger.Metadata {
    let elapsed = dispatched.duration(to: now())
    return state.withLock { value in
      func milliseconds(_ duration: Duration) -> Logger.MetadataValue {
        let parts = duration.components
        return .string(
          String(max(0, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)))
      }
      var metadata: Logger.Metadata = [
        "phase": .string(
          error == nil ? "completed" : value.headers == nil ? "before_headers" : "in_body"),
        "transport_stream": .string(String(streaming)),
        "error_type": .string(value.bodyError ?? Self.errorToken(error)),
        "elapsed_ms": milliseconds(elapsed),
        "body_bytes": .string(String(value.bytes)),
        "last_body_gap_ms": milliseconds(value.longestGap),
      ]
      if let contentType = value.contentType {
        metadata["content_type"] = .string(contentType)
      }
      if let headers = value.headers {
        metadata["headers_ms"] = milliseconds(dispatched.duration(to: headers))
      }
      if let first = value.firstBody {
        metadata["first_body_ms"] = milliseconds(dispatched.duration(to: first))
      }
      if let status = value.status, (100...599).contains(status) {
        metadata["upstream_status"] = .string(String(status))
      }
      if let id = UUID(uuidString: requestID) { metadata["request_id"] = .string(id.uuidString) }
      return metadata
    }
  }

  func record(error: (any Error)?, requestID: String) {
    guard Self.gate.withLock({ $0.admit(now: .now) }) else { return }
    Self.logger.info(
      "Native image upstream attempt", metadata: metadata(error: error, requestID: requestID))
  }
}
