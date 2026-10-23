import Foundation
import Logging
import Synchronization

/// Optional, bounded diagnostics. No client document or arbitrary error description enters logs.
enum ProtocolFailureDiagnostics {
  private static let logger = Logger(label: "codexone.protocol")
  private static let gate = Mutex(ProtocolFailureLogGate())
  private static let missingMediaTypeLogged = Mutex(false)
  private static let codes: Set<String> = [
    "invalid_api_key", "invalid_json", "invalid_request", "invalid_reference",
    "image_input_too_large", "invalid_image", "invalid_input", "invalid_mask",
    "invalid_private_context", "json_too_deep", "model_catalog_unavailable", "request_too_large",
    "too_many_references", "unsupported_background", "unsupported_compaction_trigger",
    "unsupported_image_compaction", "unsupported_stream_options",
    "unsupported_request", "unsupported_tools", "unsupported_input", "unsupported_text",
    "unsupported_reasoning", "unsupported_metadata", "unsupported_client_metadata",
    "unsupported_include", "unsupported_service_tier", "unsupported_prompt_cache",
    "unsupported_websocket_control", "invalid_websocket_lane", "unsupported_content_type",
    "model_not_allowed", "quota_or_policy_denied", "storage_pressure", "maintenance_required",
    "capacity_exceeded", "execution_indeterminate", "upstream_rejected",
    "upstream_compact_rejected",
    "upstream_upgrade_rejected", "upstream_authentication_rejected", "upstream_rate_limited",
    "upstream_unavailable", "upstream_proxy_authentication_required", "upstream_proxy_timeout",
    "upstream_proxy_failed", "invalid_upstream_content_type", "upstream_missing_terminal",
    "invalid_upstream_event",
  ]

  static func metadata(_ error: GatewayProtocolError, requestID: String) -> Logger.Metadata {
    var value: Logger.Metadata = [
      "code": .string(codes.contains(error.code) ? error.code : "other"),
      "status": .string(String(error.status)),
    ]
    if let status = error.upstreamStatus, (100...599).contains(status) {
      value["upstream_status"] = .string(String(status))
    }
    if let detail = error.detail { value["reason"] = .string(detail.rawValue) }
    if let id = UUID(uuidString: requestID) { value["request_id"] = .string(id.uuidString) }
    return value
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

  static func record(_ error: GatewayProtocolError, requestID: String) {
    guard gate.withLock({ $0.admit(now: .now) }) else { return }
    logger.warning("Protocol request rejected", metadata: metadata(error, requestID: requestID))
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
