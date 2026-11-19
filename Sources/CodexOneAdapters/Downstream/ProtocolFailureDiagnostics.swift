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

enum UpstreamFailureStage: String, Sendable {
  case webSocketConnect = "websocket_connect"
  case webSocketHandshake = "websocket_handshake"
  case webSocketTurn = "websocket_turn"
  case httpRequest = "http_request"
  case httpResponse = "http_response"
}

/// A narrow projection of a parsed request for private authorization diagnostics.
struct RequestSelectionDiagnostic: Sendable {
  let catalogModel: String?
  let logModel: String?
  let effort: String
  let legacyEffort: String?

  init(_ request: ResponseRequest, configuredModel: Bool) {
    let rawModel = request.model
    let safeIdentifier =
      (1...128).contains(rawModel.utf8.count)
      && rawModel.utf8.allSatisfy {
        (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0)
          || [45, 46, 95].contains($0)
      }
    catalogModel = safeIdentifier && configuredModel ? rawModel : nil
    let publicIdentifier =
      safeIdentifier && rawModel.utf8.count <= 64
      && rawModel.range(
        of: #"^(?:(?:gpt|codex|chatgpt)-[a-z0-9]{1,16}|o[1-9])(?:[.-][a-z0-9]{1,16})*$"#,
        options: .regularExpression) != nil
    logModel = catalogModel ?? (publicIdentifier ? rawModel : nil)
    let reasoning = request.document["reasoning"]
    if let reasoning, reasoning != .null, reasoning.object == nil {
      effort = "invalid"
    } else {
      effort = reasoning?["effort"].map(Self.effortLabel) ?? "missing"
    }
    legacyEffort = request.document["reasoning_effort"].map(Self.effortLabel)
  }

  var reasoningRejection: RejectionReason {
    if legacyEffort != nil { return .reasoningEffortLegacyField }
    switch effort {
    case "missing": return .reasoningEffortMissing
    case "invalid": return .reasoningEffortInvalid
    default: return .reasoningEffortNotAllowed
    }
  }

  private static func effortLabel(_ value: JSONValue) -> String {
    guard let effort = value.string, KeyPolicy.knownReasoningEfforts.contains(effort) else {
      return "invalid"
    }
    return effort
  }
}

/// Optional, bounded diagnostics. No client document or arbitrary error description enters logs.
enum ProtocolFailureDiagnostics {
  private static let logger = Logger(label: "codexone.protocol")
  private static let gate = Mutex(ProtocolFailureLogGate())
  private static let upstreamFirstEventGate = Mutex(ProtocolFailureLogGate())
  private static let executionTimeoutGate = Mutex(ProtocolFailureLogGate())
  private static let responseCleanupGate = Mutex(ProtocolFailureLogGate())
  private static let httpResponseWriteGate = Mutex(ProtocolFailureLogGate())
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
    "reasoning_effort_not_allowed", "unsupported_reasoning", "unsupported_metadata",
    "unsupported_client_metadata",
    "unsupported_include", "unsupported_service_tier", "unsupported_prompt_cache",
    "unsupported_websocket_control", "invalid_websocket_lane", "unsupported_content_type",
    "model_not_allowed", "quota_or_policy_denied", "storage_pressure", "maintenance_required",
    "capacity_exceeded", "capacity_exhausted", "execution_indeterminate", "upstream_rejected",
    "continuation_owner_unavailable", "account_unavailable", "account_refresh_required",
    "account_force_stopped",
    "account_authorization_required", "account_refresh_capacity", "account_state_changed",
    "account_refresh_unavailable", "pool_websocket_unavailable",
    "upstream_compact_rejected",
    "upstream_upgrade_rejected", "upstream_authentication_rejected", "upstream_rate_limited",
    "upstream_unavailable", "upstream_proxy_authentication_required", "upstream_proxy_timeout",
    "upstream_proxy_failed", "invalid_upstream_content_type", "upstream_missing_terminal",
    "invalid_upstream_event", "event_outside_upstream_turn", "incomplete_upstream_event",
    "invalid_upstream_compaction", "invalid_upstream_image", "invalid_upstream_image_format",
    "invalid_upstream_lane",
    "invalid_request_parameter", "unsupported_backend_parameter", "invalid_upstream_response",
    "invalid_upstream_output", "invalid_upstream_turn",
    "invalid_upstream_usage",
    "invalid_upstream_warmup", "unknown_upstream_lane", "unsupported_upstream_event",
    "unsupported_upstream_object", "upstream_event_too_large", "upstream_execution_failed",
    "upstream_output_too_large", "upstream_response_too_large",
  ]

  static func metadata(_ error: GatewayProtocolError, requestID: String) -> Logger.Metadata {
    var value: Logger.Metadata = [
      "code": .string(
        codes.contains(error.code) || ExecutionTimeoutReason(rawValue: error.code) != nil
          ? error.code : "other"),
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
    if let selection = error.requestSelection {
      value["requested_model"] = .string(selection.logModel ?? "unrecognized")
      value["requested_reasoning_effort"] = .string(selection.effort)
      if let legacy = selection.legacyEffort {
        value["legacy_reasoning_effort"] = .string(legacy)
      }
    }
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

  static func recordHTTPResponseWriteViolation(part: String, lastResponseID: String?) {
    guard httpResponseWriteGate.withLock({ $0.admit(now: .now) }) else { return }
    var metadata: Logger.Metadata = [
      "part": .string(part),
      "response_state": .string(part == "head" ? "awaiting_end" : "awaiting_head"),
    ]
    if let lastResponseID, let id = UUID(uuidString: lastResponseID) {
      metadata["last_response_id"] = .string(id.uuidString)
    }
    logger.warning("Invalid HTTP response write sequence", metadata: metadata)
  }

  private static let bodyTimeoutGate = Mutex(ProtocolFailureLogGate())
  static func recordRequestBodyTimeout(
    _ expiry: HTTPRequestReadDeadline.Expiry, requestID: String
  ) {
    guard let id = UUID(uuidString: requestID),
      bodyTimeoutGate.withLock({ $0.admit(now: .now) })
    else { return }
    func milliseconds(_ duration: Duration) -> String {
      let parts = duration.components
      return String(max(0, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }
    logger.warning(
      "Request body read timed out",
      metadata: [
        "request_id": .string(id.uuidString), "timeout_reason": .string(expiry.reason),
        "received_size_bucket": .string(sizeBucket(expiry.receivedBytes)),
        "body_started": .string(String(expiry.receivedBytes > 0)),
        "elapsed_ms": .string(milliseconds(expiry.elapsed)),
        "idle_ms": .string(milliseconds(expiry.idle)),
      ])
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

  static func recordExecutionTimeout(
    _ reason: ExecutionTimeoutReason, requestID: String, progress: ExecutionProgress.Snapshot?
  ) {
    guard let id = UUID(uuidString: requestID),
      executionTimeoutGate.withLock({ $0.admit(now: .now) })
    else { return }
    var metadata: Logger.Metadata = [
      "request_id": .string(id.uuidString),
      "reason": .string(reason.rawValue),
    ]
    if let event = progress?.lastEvent, let at = progress?.lastEventAt {
      metadata["last_progress_event"] = .string(event)
      metadata["last_progress_at_unix_ms"] = .string(String(Int64(at.timeIntervalSince1970 * 1000)))
    }
    if let remaining = progress?.remaining {
      let parts = remaining.components
      metadata["progress_deadline_remaining_ms"] = .string(
        String(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }
    logger.warning("Responses execution deadline reached", metadata: metadata)
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

  static func recordUpstreamBeforeFirstEvent(
    _ error: any Error, stage: UpstreamFailureStage, context: ExecutionContext,
    responseStatus: Int? = nil
  ) {
    guard !context.hasUpstreamEvent, !Task.isCancelled, !(error is CancellationError),
      let requestID = context.admission.requestID.flatMap(UUID.init(uuidString:)),
      upstreamFirstEventGate.withLock({ $0.admit(now: .now) })
    else { return }
    let mapped = protocolFailure(error)
    let status = (mapped.upstreamStatus ?? responseStatus).flatMap {
      (100...599).contains($0) ? $0 : nil
    }
    let classification =
      if mapped.code == "upstream_authentication_rejected" {
        "authentication_rejected"
      } else if status != nil {
        "upstream_status_observed"
      } else if stage == .webSocketTurn {
        "no_provider_event"
      } else {
        "no_upstream_status"
      }
    var metadata: Logger.Metadata = [
      "request_id": .string(requestID.uuidString),
      "stage": .string(stage.rawValue),
      "classification": .string(classification),
      "cause": .string(mapped.detail?.rawValue ?? causeToken(error)),
    ]
    if let status { metadata["upstream_status"] = .string(String(status)) }
    if let version = context.admission.accountSnapshot?.credentialVersion {
      metadata["credential_version"] = .string(String(version))
    }
    logger.warning("Upstream failed before first event", metadata: metadata)
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
