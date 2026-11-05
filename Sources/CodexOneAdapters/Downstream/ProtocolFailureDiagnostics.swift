import CodexOneCore
import Foundation
import Logging
import NIOCore
import NIOWebSocket
import Synchronization

enum ResponseStreamFinishReason: String, Sendable {
  case downstreamDoneWrite = "downstream_done_write"
  case downstreamEndWrite = "downstream_end_write"
}

enum ResponseCleanupReason: String, Sendable {
  case executionCleanupCancelled = "execution_cleanup_cancelled"
  case downstreamIdleRead = "downstream_idle_read"
}

/// Optional, bounded diagnostics. No client document or arbitrary error description enters logs.
enum ProtocolFailureDiagnostics {
  private static let logger = Logger(label: "codexone.protocol")
  private static let gate = Mutex(ProtocolFailureLogGate())
  private static let responseCleanupGate = Mutex(ProtocolFailureLogGate())
  private static let missingMediaTypeLogged = Mutex(false)
  private static let codes: Set<String> = [
    "request_body_timeout", "invalid_api_key", "invalid_json", "invalid_request",
    "invalid_reference",
    "conversation_too_large", "image_input_too_large", "invalid_image", "invalid_input",
    "invalid_mask", "unsupported_svg_model_selection", "unsupported_image_format_combination",
    "invalid_private_context", "json_too_deep", "model_catalog_unavailable", "request_too_large",
    "too_many_references", "unsupported_background", "unsupported_compaction_trigger",
    "unsupported_stream_options",
    "unsupported_request", "unsupported_tools", "unsupported_input", "unsupported_text",
    "unsupported_reasoning", "unsupported_metadata", "unsupported_client_metadata",
    "unsupported_include", "unsupported_service_tier", "unsupported_prompt_cache",
    "unsupported_websocket_control", "invalid_websocket_lane", "unsupported_content_type",
    "model_not_allowed", "quota_or_policy_denied", "storage_pressure", "maintenance_required",
    "capacity_exceeded", "capacity_exhausted", "execution_indeterminate", "upstream_rejected",
    "upstream_compact_rejected",
    "upstream_upgrade_rejected", "upstream_authentication_rejected", "upstream_rate_limited",
    "upstream_unavailable", "upstream_proxy_authentication_required", "upstream_proxy_timeout",
    "upstream_proxy_failed", "invalid_upstream_content_type", "upstream_missing_terminal",
    "invalid_upstream_event", "event_outside_upstream_turn", "incomplete_upstream_event",
    "invalid_upstream_compaction", "invalid_upstream_image", "invalid_upstream_lane",
    "invalid_request_parameter", "unsupported_backend_parameter", "invalid_upstream_response",
    "invalid_upstream_output", "invalid_upstream_turn",
    "invalid_upstream_usage",
    "invalid_upstream_warmup", "unknown_upstream_lane", "unsupported_upstream_event",
    "unsupported_upstream_object", "upstream_event_too_large", "upstream_execution_failed",
    "upstream_output_too_large", "upstream_response_too_large",
  ]

  static func metadata(_ error: GatewayProtocolError, requestID: String) -> Logger.Metadata {
    var value: Logger.Metadata = [
      "code": .string(codes.contains(error.code) ? error.code : "other"),
      "status": .string(String(error.status)),
    ]
    if let status = error.upstreamStatus, (100...599).contains(status) {
      value["upstream_status"] = .string(String(status))
    }
    if let code = error.upstreamWebSocketCloseCode, (1000...4999).contains(code) {
      value["upstream_ws_close_code"] = .string(String(code))
    }
    if let detail = error.detail { value["reason"] = .string(detail.rawValue) }
    // Provider codes are short machine identifiers; free text never enters logs.
    if let code = error.providerError?["code"]?.string ?? error.providerError?["type"]?.string,
      (1...64).contains(code.utf8.count),
      code.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 || (48...57).contains($0) })
    {
      value["provider_code"] = .string(code)
    }
    if let id = UUID(uuidString: requestID) { value["request_id"] = .string(id.uuidString) }
    return value
  }

  static func sizeBucket(_ bytes: Int) -> String {
    if bytes <= 16 * 1024 * 1024 { return "at_most_16_mib" }
    if bytes <= 24 * 1024 * 1024 { return "16_to_24_mib" }
    if bytes <= 32 * 1024 * 1024 { return "24_to_32_mib" }
    return "over_32_mib"
  }

  static func recordOversizedFrame(bytes: Int, path: String, closeCode: UInt16? = nil) {
    recordBodyLimit(bytes: bytes, path: path, closeCode: closeCode)
  }

  private static let bodyLimitGate = Mutex(ProtocolFailureLogGate())
  static func recordBodyLimit(bytes: Int, path: String, closeCode: UInt16? = nil) {
    guard bodyLimitGate.withLock({ $0.admit(now: .now) }) else { return }
    var metadata: Logger.Metadata = [
      "size_bucket": .string(sizeBucket(bytes)), "path": .string(path),
    ]
    if let closeCode { metadata["upstream_ws_close_code"] = .string(String(closeCode)) }
    logger.info("Request body size boundary", metadata: metadata)
  }

  private static let uploadGate = Mutex(ProtocolFailureLogGate())
  static func recordUpload(
    bytes: Int, duration: Duration, transport: String, sent: Bool,
    encoding: String? = nil, wireBytes: Int = 0, compression: Duration = .zero
  ) {
    guard bytes > 8 * 1024 * 1024,
      uploadGate.withLock({ $0.admit(now: .now) })
    else { return }
    let bucket =
      duration < .seconds(1)
      ? "under_1_s"
      : duration < .seconds(10)
        ? "1_to_10_s"
        : duration < .seconds(30)
          ? "10_to_30_s"
          : duration < .seconds(60) ? "30_to_60_s" : "at_least_60_s"
    var metadata: Logger.Metadata = [
      "size_bucket": .string(sizeBucket(bytes)), "upload_duration_bucket": .string(bucket),
      "transport": .string(transport), "result": .string(sent ? "sent" : "interrupted"),
    ]
    if let encoding {
      metadata["content_encoding"] = .string(encoding)
      let wireBucket =
        wireBytes <= 1024 * 1024
        ? "at_most_1_mib"
        : wireBytes <= 4 * 1024 * 1024
          ? "1_to_4_mib"
          : wireBytes <= 8 * 1024 * 1024
            ? "4_to_8_mib"
            : wireBytes <= 16 * 1024 * 1024
              ? "8_to_16_mib"
              : wireBytes <= 24 * 1024 * 1024
                ? "16_to_24_mib"
                : wireBytes <= 32 * 1024 * 1024 ? "24_to_32_mib" : "over_32_mib"
      metadata["wire_size_bucket"] = .string(wireBucket)
      let compressionBucket =
        encoding == "identity"
        ? "not_applicable"
        : compression < .milliseconds(1)
          ? "under_1_ms"
          : compression < .milliseconds(10)
            ? "1_to_10_ms"
            : compression < .milliseconds(100)
              ? "10_to_100_ms"
              : compression < .seconds(1) ? "100_to_1000_ms" : "at_least_1000_ms"
      metadata["compression_duration_bucket"] = .string(compressionBucket)
    }
    logger.info("Upstream request upload", metadata: metadata)
  }

  static func recordMissingStreamMediaType(requestID: String) {
    guard let id = UUID(uuidString: requestID) else { return }
    let first = missingMediaTypeLogged.withLock { logged in
      guard !logged else { return false }
      logged = true
      return true
    }
    guard first else { return }
    logger.info(
      "Upstream stream omitted media type; SSE validation required",
      metadata: ["upstream_status": "200", "request_id": .string(id.uuidString)])
  }

  static func recordStreamFinish(_ reason: ResponseStreamFinishReason, requestID: String) {
    guard let id = UUID(uuidString: requestID),
      responseCleanupGate.withLock({ $0.admit(now: .now) })
    else { return }
    logger.info(
      "Response stream finish failed after execution",
      metadata: ["reason": .string(reason.rawValue), "request_id": .string(id.uuidString)])
  }

  static func recordResponseCleanup(_ reason: ResponseCleanupReason, requestID: String) {
    guard let id = UUID(uuidString: requestID),
      responseCleanupGate.withLock({ $0.admit(now: .now) })
    else { return }
    logger.info(
      "Response cleanup after completion",
      metadata: ["reason": .string(reason.rawValue), "request_id": .string(id.uuidString)])
  }

  static func causeToken(_ error: any Error) -> String {
    if let error = error as? ChannelError {
      switch error {
      case .ioOnClosedChannel: return "channel_closed"
      case .alreadyClosed: return "channel_already_closed"
      case .eof: return "channel_eof"
      case .inputClosed: return "channel_input_closed"
      case .outputClosed: return "channel_output_closed"
      case .connectTimeout: return "channel_connect_timeout"
      case .connectPending: return "channel_connect_pending"
      case .operationUnsupported: return "channel_operation_unsupported"
      case .inappropriateOperationForState: return "channel_invalid_state"
      default: return "channel_other"
      }
    }
    if let error = error as? NIOWebSocketError {
      switch error {
      case .invalidFrameLength: return "websocket_invalid_frame_length"
      case .fragmentedControlFrame: return "websocket_fragmented_control"
      case .multiByteControlFrameLength: return "websocket_control_length"
      }
    }
    if error is DecodingError { return "json_decode" }
    if error is EncodingError { return "json_encode" }
    if let error = error as? ExecutionError {
      switch error {
      case .closed: return "execution_closed"
      case .conflict: return "execution_conflict"
      case .invalidCommand: return "execution_invalid_command"
      case .storageUnavailable: return "execution_storage_unavailable"
      default: return "execution_other"
      }
    }
    // Fixed HTTP client cases, bounded errno, cancellation, or other; never descriptions.
    return NativeImageDiagnostics.errorToken(error)
  }

  static func record(
    _ error: GatewayProtocolError, requestID: String, cause: (any Error)? = nil
  ) {
    guard gate.withLock({ $0.admit(now: .now) }) else { return }
    var value = metadata(error, requestID: requestID)
    if let cause { value["cause"] = .string(causeToken(cause)) }
    logger.warning("Protocol request rejected", metadata: value)
  }
}

struct ProtocolFailureLogGate: Sendable {
  private var start: ContinuousClock.Instant?
  private var count = 0

  mutating func admit(now: ContinuousClock.Instant) -> Bool {
    if start == nil || start!.duration(to: now) >= .seconds(60) {
      start = now
      count = 0
    }
    guard count < 16 else { return false }
    count += 1
    return true
  }
}
