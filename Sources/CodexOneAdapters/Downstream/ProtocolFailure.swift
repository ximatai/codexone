import AsyncHTTPClient
import CodexOneCore
import Foundation

func protocolFailure(_ error: any Error) -> GatewayProtocolError {
  if let error = error as? GatewayProtocolError { return error }
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
  if let error = error as? AccountDispatchError {
    return .init(
      503, error == .refreshRequired ? "account_refresh_required" : "account_unavailable")
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
    case .unauthorized: return .init(401, "invalid_api_key")
    case .storagePressure: return .init(503, "storage_pressure")
    case .maintenanceRequired: return .init(503, "maintenance_required")
    case .denied: return .init(429, "quota_or_policy_denied")
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
  if diagnostics { ProtocolFailureDiagnostics.record(mapped, requestID: requestID) }
  let message =
    UUID(uuidString: requestID) != nil
    ? "Gateway request failed. Reference: \(requestID)." : "Gateway request failed."
  var fields: [String: JSONValue] = [
    "type": .string(mapped.status < 500 ? "invalid_request_error" : "server_error"),
    "code": .string(mapped.code), "message": .string(message),
  ]
  // Provider members win so clients see the same actionable error as a direct connection.
  for (key, value) in mapped.providerError?.object ?? [:] { fields[key] = value }
  fields["request_id"] = .string(requestID)
  return .object(["error": .object(fields)])
}
