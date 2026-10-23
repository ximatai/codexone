import CodexOneCore
import Foundation
import NIOHTTP1

func upstreamRejection(status: HTTPResponseStatus, headers: HTTPHeaders, compact: Bool = false)
  -> GatewayProtocolError
{
  let retry = headers["retry-after"]
  let seconds: Int64?
  if retry.count == 1, retry[0].utf8.count <= 10,
    retry[0].utf8.allSatisfy({ (48...57).contains($0) }),
    let raw = Int64(retry[0])
  {
    seconds = min(3600, max(1, raw))
  } else {
    seconds = nil
  }
  if status == .unauthorized { return .init(502, "upstream_authentication_rejected") }
  if status == .tooManyRequests {
    return .init(429, "upstream_rate_limited", cooldownSeconds: seconds)
  }
  if (500...599).contains(Int(status.code)) {
    return .init(502, "upstream_unavailable", cooldownSeconds: seconds)
  }
  return .init(502, compact ? "upstream_compact_rejected" : "upstream_rejected")
}
func executionFailure(_ error: any Error) -> ExecutionFailure {
  if error is CancellationError { return .clientCancelled }
  if let error = error as? GatewayProtocolError {
    switch error.code {
    case "upstream_authentication_rejected": return .authenticationRejected
    case "upstream_rate_limited": return .rateLimited
    case "upstream_unavailable": return .upstreamUnavailable
    case "upstream_rejected", "upstream_compact_rejected", "upstream_upgrade_rejected",
      "upstream_execution_failed":
      return .upstreamRejected
    case "execution_deadline_exceeded", "execution_first_response_timeout",
      "execution_progress_timeout":
      return .deadlineExceeded
    case "model_not_allowed": return .modelNotAllowed
    default:
      if error.code.hasPrefix("invalid_upstream") { return .invalidUpstreamResponse }
      return Task.isCancelled ? .clientCancelled : .indeterminate
    }
  }
  if let error = error as? ExecutionError {
    switch error {
    case .unauthorized: return .keyRejected
    case .denied, .capacity: return .localCapacity
    case .unknownObject: return .objectUnavailable
    case .ambiguousObject: return .objectAmbiguous
    case .invalidCommand: return .invalidRequest
    case .storageUnavailable: return .storageUnavailable
    default: return .indeterminate
    }
  }
  if error is AccountDispatchError || error is AccountRefreshError { return .accountUnavailable }
  return Task.isCancelled ? .clientCancelled : .indeterminate
}
func observeExecution(
  _ context: ExecutionContext, operation: @Sendable () async throws -> UsageEvidence?
) async throws -> UsageEvidence? {
  do { return try await operation() } catch {
    try? context.observeOutcome(
      .init(
        failure: executionFailure(error), atUnixSeconds: Int64(Date().timeIntervalSince1970),
        cooldownSeconds: (error as? GatewayProtocolError)?.cooldownSeconds))
    throw error
  }
}

/// A failed terminal response can carry complete usage. Result and evidence are independent.
func observeTerminalOutcome(_ event: JSONValue, context: ExecutionContext) throws {
  let type = event["type"]?.string
  guard type == "response.failed" || type == "response.incomplete" else { return }
  try context.observeOutcome(
    .init(
      failure: type == "response.failed" ? .upstreamRejected : .indeterminate,
      atUnixSeconds: Int64(Date().timeIntervalSince1970)))
}
