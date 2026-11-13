import AsyncHTTPClient
import CodexOneCore
import Foundation

func protocolFailure(_ error: any Error) -> GatewayProtocolError {
  if let error = error as? GatewayProtocolError { return error }
  if error is AccountExecutionStopped { return .init(503, "account_force_stopped") }
  // HTTP→WS bridges retain their existing failure contract; native connections consume this signal.
  if error is WebSocketUpstreamClosed {
    return .init(502, "invalid_upstream_turn", detail: .upstreamTurnLifecycle)
  }
  if let error = error as? HTTPClientError {
    if error == .proxyAuthenticationRequired {
      return .init(502, "upstream_proxy_authentication_required", upstreamStatus: 407)
    }
    if error == .httpProxyHandshakeTimeout { return .init(502, "upstream_proxy_timeout") }
    if error == .invalidProxyResponse { return .init(502, "upstream_proxy_failed") }
  }
  if let error = error as? AccountCooldownUnavailable {
    return .init(
      503, "account_unavailable", cooldownSeconds: error.retryAfter, detail: .accountCooldown)
  }
  if let error = error as? AccountDispatchError {
    return .init(
      503, error == .refreshRequired ? "account_refresh_required" : "account_unavailable",
      detail: error == .refreshRequired ? nil : .accountDispatchUnavailable)
  }
  if let error = error as? AccountRefreshError {
    switch error {
    case .authorizationRequired: return .init(503, "account_authorization_required")
    case .capacity, .closed: return .init(503, "account_refresh_capacity")
    case .conflict: return .init(503, "account_state_changed")
    case .storageUnavailable: return .init(503, "storage_unavailable")
    default: return .init(502, "account_refresh_unavailable")
    }
  }
  if let error = error as? ExecutionError {
    switch error {
    case .keyExpired: return .init(401, "api_key_expired")
    case .unauthorized: return .init(401, "invalid_api_key")
    case .storagePressure: return .init(503, "storage_pressure")
    case .maintenanceRequired: return .init(503, "maintenance_required")
    case .denied: return .init(429, "quota_or_policy_denied")
    case .accountConcurrency: return .init(429, "account_concurrency_exceeded")
    case .unknownObject, .ambiguousObject: return .init(400, "unknown_or_ambiguous_object")
    case .capacity: return .init(503, "capacity_exceeded")
    default: return .init(503, "execution_indeterminate")
    }
  }
  return .init(502, "execution_indeterminate")
}

func protocolErrorEnvelope(_ error: any Error, requestID: String, diagnostics: Bool = true)
  -> JSONValue
{
  let mapped = protocolFailure(error)
  if diagnostics {
    ProtocolFailureDiagnostics.record(
      mapped, requestID: requestID,
      cause: mapped.code == "execution_indeterminate" && !(error is GatewayProtocolError)
        ? error : nil)
  }
  let explanation =
    switch mapped.code {
    case "model_not_allowed":
      "The selected model is not available for this request. Choose a model enabled for this operation and allowed by your API key."
    case UpstreamWebSocketBodyLimit.errorCode:
      "The conversation or its images are too large. Start a new session or remove images before trying again."
    case "account_force_stopped":
      "An administrator stopped this account while the request was in progress. The upstream execution result may be unknown."
    case "continuation_owner_unavailable":
      "Continuation source cannot be verified. The request was not dispatched."
    case "unsupported_svg_model_selection":
      "Choosing an SVG author model is not supported. Omit the svg object to use the image endpoint default. The request was not dispatched."
    case "unsupported_image_format_combination":
      "This image format cannot use streaming, partial images, masks or output compression. SVG also requires generation with one image and no prompt rewriter. The request was not dispatched."
    case "invalid_upstream_image_format":
      "The provider returned a different or unrecognized image format."
    default:
      "Gateway request failed."
    }
  let message =
    UUID(uuidString: requestID) != nil
    ? "\(explanation) Reference: \(requestID)." : explanation
  // Retain the provider's received order; gateway defaults append only missing members.
  var fields = mapped.providerError?.object ?? [:]
  if fields["type"] == nil {
    fields["type"] = .string(mapped.status < 500 ? "invalid_request_error" : "server_error")
  }
  if fields["code"] == nil { fields["code"] = .string(mapped.code) }
  if fields["message"] == nil { fields["message"] = .string(message) }
  fields["request_id"] = .string(requestID)
  return .object(["error": .object(fields)])
}
