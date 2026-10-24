import Foundation

/// Selected by trusted assembly, never by downstream request fields.
enum ResponseRequestContract: String, Sendable {
  case responses
  case codexSubscription = "codex-subscription"
}

extension ResponseRequest {
  static func validateParameters(_ fields: [String: JSONValue]) throws {
    for (key, lower, upper) in [
      ("temperature", Decimal(0), Decimal(2)),
      ("top_p", Decimal(0), Decimal(1)),
    ] {
      if let value = fields[key], value != .null {
        guard case .number(let number) = value, number >= lower, number <= upper else {
          throw GatewayProtocolError(400, "invalid_request_parameter")
        }
      }
    }
    if let value = fields["max_output_tokens"], value != .null {
      guard let count = value.integer, count >= 16 else {
        throw GatewayProtocolError(400, "invalid_request_parameter")
      }
    }
    for (key, choices) in [
      ("service_tier", ["auto", "default", "flex", "scale", "priority", "fast", "ultrafast"]),
      ("truncation", ["auto", "disabled"]),
      ("prompt_cache_retention", ["in_memory", "24h"]),
    ] {
      if let value = fields[key], value != .null, !choices.contains(value.string ?? "") {
        throw GatewayProtocolError(400, "invalid_request_parameter")
      }
    }
  }

  /// Validate before admission as well as at serialization; no attempt or quota on local rejection.
  func preparedDocument(contract: ResponseRequestContract, nativeWebSocket: Bool) throws
    -> JSONValue
  {
    guard contract == .codexSubscription, requirements.imageModel == nil,
      mode != .compact || streamCompaction
    else { return document }
    var fields = document.object!
    for key in [
      "max_output_tokens", "temperature", "top_p", "truncation",
      "prompt_cache_retention", "metadata",
    ] {
      guard fields[key] == nil || fields[key] == .null else {
        throw GatewayProtocolError(400, "unsupported_backend_parameter")
      }
      fields.removeValue(forKey: key)
    }
    guard fields["store"]?.bool != true,
      nativeWebSocket || fields["previous_response_id"] == nil
        || fields["previous_response_id"] == .null,
      fields["service_tier"] == nil || fields["service_tier"] == .null
        || ["auto", "default", "priority"].contains(fields["service_tier"]?.string ?? "")
    else { throw GatewayProtocolError(400, "unsupported_backend_parameter") }
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
