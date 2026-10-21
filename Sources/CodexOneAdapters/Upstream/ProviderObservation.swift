import CodexOneCore
import Foundation

/// Provider-specific evidence extraction; downstream documents are never used as execution proof.
struct ProviderObservation: Sendable {
  let bindings: [ObjectBinding]
  let usage: UsageEvidence?
  let terminal: Bool

  init(event: JSONValue, model: SingleIdentityConfiguration.Model, functionNames: Set<String>)
    throws
  {
    guard let type = event["type"]?.string else {
      throw GatewayProtocolError(502, "unsupported_upstream_event")
    }
    let transparent: Set<String> = [
      "response.output_text.delta", "response.output_text.done",
      "response.function_call_arguments.delta", "response.function_call_arguments.done",
      "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
      "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
      "response.content_part.added", "response.content_part.done", "response.refusal.delta",
      "response.refusal.done",
    ]
    let responseEvents: Set<String> = [
      "response.created", "response.in_progress", "response.completed", "response.failed",
      "response.incomplete",
    ]
    let itemEvents: Set<String> = ["response.output_item.added", "response.output_item.done"]
    var bindings: [ObjectBinding] = []
    var usage: UsageEvidence?
    let terminal = ["response.completed", "response.failed", "response.incomplete"].contains(type)
    if responseEvents.contains(type) {
      guard let response = event["response"], let id = response["id"]?.string,
        !id.isEmpty, id.utf8.count <= 256
      else { throw GatewayProtocolError(502, "invalid_upstream_response") }
      guard response["background"]?.bool != true,
        response["conversation"] == nil || response["conversation"] == .null,
        response["prompt"] == nil || response["prompt"] == .null,
        response["tools"] == nil
          || response["tools"]?.array?.allSatisfy({ $0["type"]?.string == "function" }) == true
      else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      bindings.append(.init(type: "response", rawID: id))
      if let output = response["output"]?.array {
        guard output.count <= 16 else {
          throw GatewayProtocolError(502, "upstream_output_too_large")
        }
        for item in output { bindings += try Self.itemBindings(item, functionNames: functionNames) }
      }
      if terminal { usage = try Self.usage(response["usage"], model: model) }
    } else if itemEvents.contains(type), let item = event["item"] {
      bindings += try Self.itemBindings(item, functionNames: functionNames)
    } else if transparent.contains(type) {
      if let id = event["item_id"]?.string {
        guard !id.isEmpty, id.utf8.count <= 256 else {
          throw GatewayProtocolError(502, "invalid_upstream_response")
        }
        bindings.append(.init(type: "item", rawID: id))
      }
      if let part = event["part"] {
        try Self.validatePart(part, allowSummary: true)
      }
    } else {
      throw GatewayProtocolError(502, "unsupported_upstream_event")
    }
    self.bindings = bindings
    self.usage = usage
    self.terminal = terminal
  }

  private static func itemBindings(_ item: JSONValue, functionNames: Set<String>) throws
    -> [ObjectBinding]
  {
    guard let type = item["type"]?.string,
      ["message", "function_call", "reasoning"].contains(type),
      let id = item["id"]?.string, !id.isEmpty, id.utf8.count <= 256
    else {
      throw GatewayProtocolError(502, "unsupported_upstream_object")
    }
    let allowedKeys: Set<String> = [
      "type", "id", "status", "role", "content", "name", "arguments", "call_id", "summary",
      "encrypted_content",
    ]
    guard item.object?.keys.allSatisfy(allowedKeys.contains) == true else {
      throw GatewayProtocolError(502, "unsupported_upstream_object")
    }
    var bindings: [ObjectBinding] = [.init(type: "item", rawID: id)]
    if type == "message" {
      guard let content = item["content"]?.array, content.count <= 128 else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      for part in content { try Self.validatePart(part, allowSummary: false) }
    }
    if type == "function_call" {
      guard let name = item["name"]?.string, functionNames.contains(name),
        let call = item["call_id"]?.string, !call.isEmpty, call.utf8.count <= 256
      else {
        throw GatewayProtocolError(502, "invalid_upstream_response")
      }
      bindings.append(.init(type: "function_call", rawID: call))
    }
    if let summary = item["summary"] {
      guard type == "reasoning", let parts = summary.array, parts.count <= 128 else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      for part in parts { try Self.validatePart(part, allowSummary: true) }
    }
    if item["encrypted_content"] != nil {
      throw GatewayProtocolError(502, "unsupported_upstream_object")
    }
    return bindings
  }

  private static func validatePart(_ part: JSONValue, allowSummary: Bool) throws {
    let type = part["type"]?.string ?? ""
    let allowedTypes =
      allowSummary ? ["output_text", "refusal", "summary_text"] : ["output_text", "refusal"]
    let text = type == "refusal" ? part["refusal"]?.string : part["text"]?.string
    guard allowedTypes.contains(type), text != nil,
      part["annotations"] == nil || part["annotations"]?.array == [],
      part["logprobs"] == nil || part["logprobs"] == .null || part["logprobs"]?.array == [],
      part.object?.keys.allSatisfy({
        ["type", "text", "refusal", "annotations", "logprobs"].contains($0)
      }) == true
    else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
  }

  static func usage(_ value: JSONValue?, model: SingleIdentityConfiguration.Model) throws
    -> UsageEvidence?
  {
    guard let value, value != .null else { return nil }
    func count(_ value: JSONValue?) throws -> Int64? {
      guard let value, value != .null else { return nil }
      guard let number = value.integer, (0...1_000_000_000).contains(number) else {
        throw GatewayProtocolError(502, "invalid_upstream_usage")
      }
      return number
    }
    let observedInput = try count(value["input_tokens"])
    let observedOutput = try count(value["output_tokens"])
    let cached = try count(value["input_tokens_details"]?["cached_tokens"])
    guard observedInput != nil || observedOutput != nil || cached != nil else { return nil }
    if let observedInput, let cached, cached > observedInput {
      throw GatewayProtocolError(502, "invalid_upstream_usage")
    }
    let input = max(observedInput ?? 0, cached ?? 0)
    let output = observedOutput ?? 0
    // Configured list-price estimate, explicitly unrelated to subscription window balance.
    let inputCost = input.multipliedReportingOverflow(by: model.inputMicrosPerMillion)
    let outputCost = output.multipliedReportingOverflow(by: model.outputMicrosPerMillion)
    let total = inputCost.partialValue.addingReportingOverflow(outputCost.partialValue)
    guard !inputCost.overflow, !outputCost.overflow, !total.overflow else {
      throw GatewayProtocolError(502, "invalid_upstream_usage")
    }
    let micros = total.partialValue / 1_000_000 + (total.partialValue % 1_000_000 == 0 ? 0 : 1)
    return .init(
      revision: 1, inputTokens: input, outputTokens: output, cachedTokens: cached ?? 0,
      images: 0, estimatedMicros: micros,
      completeness: observedInput != nil && observedOutput != nil && cached != nil
        ? .complete : .partial)
  }
}
