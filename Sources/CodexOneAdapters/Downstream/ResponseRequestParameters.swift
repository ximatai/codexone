import Foundation

/// Selected by trusted assembly, never by downstream request fields.
enum ResponseRequestContract: String, Sendable {
  case responses
  case codexSubscription = "codex-subscription"
}

extension ResponseRequest {
  /// Validate before admission as well as at serialization; no attempt or quota on local rejection.
  func preparedDocument(contract: ResponseRequestContract, nativeWebSocket: Bool) throws
    -> JSONValue
  {
    guard contract == .codexSubscription,
      mode != .compact || streamCompaction
    else { return document }
    var fields = document.object!
    for (key, detail): (String, ProtocolRejectionDetail) in [
      ("max_output_tokens", .backendMaxOutputTokens), ("temperature", .backendTemperature),
      ("top_p", .backendTopP), ("truncation", .backendTruncation),
      ("prompt_cache_retention", .backendPromptCacheRetention), ("metadata", .backendMetadata),
    ] {
      guard fields[key] == nil || fields[key] == .null else {
        throw GatewayProtocolError(400, "unsupported_backend_parameter", detail: detail)
      }
      fields.removeValue(forKey: key)
    }
    guard fields["store"]?.bool != true else {
      throw GatewayProtocolError(400, "unsupported_backend_parameter", detail: .backendStore)
    }
    guard
      nativeWebSocket || fields["previous_response_id"] == nil
        || fields["previous_response_id"] == .null
    else {
      throw GatewayProtocolError(
        400, "unsupported_backend_parameter", detail: .backendPreviousResponseID)
    }
    for key in ["service_tier", "previous_response_id"] where fields[key] == .null {
      fields.removeValue(forKey: key)
    }
    fields["store"] = .bool(false)
    fields["stream"] = .bool(true)
    if let input = fields["input"]?.string {
      fields["input"] = .array([.object(["role": .string("user"), "content": .string(input)])])
    }
    return .object(fields)
  }
}
