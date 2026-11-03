import Foundation

/// Provider-observed boundary inferred from acceptance tests, not a stable provider contract.
/// Limit applies to encoded message payload bytes, excluding WebSocket framing/masking.
enum UpstreamWebSocketBodyLimit {
  static let maximumMessageBytes = 16 * 1024 * 1024
  static let errorCode = "conversation_too_large"

  static func rejection(upstreamStatus: Int? = nil) -> GatewayProtocolError {
    .init(
      413, errorCode, upstreamStatus: upstreamStatus,
      explicitProviderRejection: upstreamStatus != nil)
  }

  /// Native clients may submit incremental input even without previous_response_id.
  /// Their socket history, controls, lanes and warmup cannot be moved to a new HTTP exchange.
  static func requireNativeFrame(_ frame: Data) throws {
    guard frame.count > maximumMessageBytes else { return }
    ProtocolFailureDiagnostics.recordOversizedFrame(bytes: frame.count, path: "reject_native")
    throw rejection()
  }
}
