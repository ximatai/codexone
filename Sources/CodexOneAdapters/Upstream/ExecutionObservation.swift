import CodexOneCore
import Foundation
import NIOHTTP1

func upstreamRejection(status: HTTPResponseStatus, headers: HTTPHeaders, compact: Bool = false)
  -> GatewayProtocolError
{
  if (500...599).contains(Int(status.code)) {
    return .init(
      502, "upstream_unavailable", cooldownSeconds: ProviderError.retryAfter(headers),
      upstreamStatus: Int(status.code))
  }
  return ProviderError.failure(
    status: Int(status.code), error: nil,
    retryAfter: ProviderError.retryAfter(headers), compact: compact)
}
func executionFailure(_ error: any Error) -> ExecutionFailure {
  if error is CancellationError { return .clientCancelled }
  // Raised only before a turn is written upstream: the pinned socket was already gone.
  if error is WebSocketUpstreamClosed { return .upstreamUnavailable }
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
    case "upstream_response_too_large", "upstream_event_too_large": return .invalidUpstreamResponse
    case "model_not_allowed": return .modelNotAllowed
    default:
      if error.code.hasPrefix("invalid_upstream") { return .invalidUpstreamResponse }
      return Task.isCancelled ? .clientCancelled : .indeterminate
    }
  }
  if let error = error as? ExecutionError {
    switch error {
    case .unauthorized, .keyExpired: return .keyRejected
    case .denied, .capacity, .accountConcurrency: return .localCapacity
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
    if let error = error as? GatewayProtocolError, error.explicitProviderRejection,
      !context.hasProviderEvents
    {
      try? observeProviderRejection(context)
    }
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

/// A validated, bound terminal has been submitted downstream; cleanup cannot rewrite it.
func observeSubmittedTerminal(_ event: JSONValue, context: ExecutionContext) throws {
  guard event["type"]?.string == "response.completed" else { return }
  try context.observeOutcome(
    .init(failure: nil, atUnixSeconds: Int64(Date().timeIntervalSince1970)))
}

/// Explicit provider proof is the only exception to missing usage remaining unknown.
func observeProviderRejection(_ context: ExecutionContext) throws {
  let images = context.admission.executionRequirements.imageModel != nil
  let nativeImages = context.admission.executionRequirements.route == .images
  try context.observeUsage(
    .init(
      revision: 1, inputTokens: 0, outputTokens: 0,
      cachedTokens: 0, images: 0, estimatedMicros: 0, completeness: .complete,
      imageInputTokens: images ? 0 : nil, imageOutputTokens: images ? 0 : nil,
      imageInputTextTokens: images ? 0 : nil, imageInputImageTokens: images ? 0 : nil,
      nativeImages: nativeImages ? true : nil, providerRejectedBeforeOutput: true))
}

/// Only the first parsed event can certify a refusal. Even a lifecycle event closes this gate.
func observeProviderEvent(_ event: JSONValue, context: ExecutionContext) throws {
  let first = context.observeProviderEvent()
  guard first, ["error", "response.failed"].contains(event["type"]?.string ?? ""),
    event["response"]?["output"] == nil || event["response"]?["output"] == .array([]),
    event["output"] == nil || event["output"] == .array([]),
    event["response"]?["usage"] == nil || event["response"]?["usage"] == .null,
    event["item"] == nil, event["delta"] == nil
  else { return }
  let response = event["response"] ?? event
  let error = response["error"] ?? event["error"] ?? event
  let status =
    event["status"]?.integer ?? event["status_code"]?.integer
    ?? response["status_code"]?.integer ?? error["status"]?.integer ?? error["status_code"]?.integer
  guard ProviderError.isExplicitRejection(status: status.map(Int.init), error: error) else {
    return
  }
  try observeProviderRejection(context)
}
