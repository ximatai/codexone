import CodexOneCore

func protocolFailure(_ error: any Error) -> GatewayProtocolError {
  if let error = error as? GatewayProtocolError { return error }
  if let error = error as? ExecutionError {
    switch error {
    case .unauthorized: return .init(401, "invalid_api_key")
    case .denied: return .init(429, "quota_or_policy_denied")
    case .unknownObject, .ambiguousObject: return .init(400, "unknown_or_ambiguous_object")
    case .capacity: return .init(503, "capacity_exceeded")
    default: return .init(503, "execution_indeterminate")
    }
  }
  return .init(502, "execution_indeterminate")
}

func protocolErrorEnvelope(_ error: any Error, requestID: String) -> JSONValue {
  let mapped = protocolFailure(error)
  return .object([
    "error": .object([
      "type": .string(mapped.status < 500 ? "invalid_request_error" : "server_error"),
      "code": .string(mapped.code), "message": .string("Gateway request failed."),
      "request_id": .string(requestID),
    ])
  ])
}
