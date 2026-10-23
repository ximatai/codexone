import CodexOneCore
import Foundation

/// Provider-specific evidence extraction; downstream documents are never used as execution proof.
struct ProviderObservation: Sendable {
  let bindings: [ObjectBinding]
  let usage: UsageEvidence?
  let terminal: Bool

  static let transparentEvents: Set<String> = [
    "response.output_text.delta", "response.output_text.done",
    "response.function_call_arguments.delta", "response.function_call_arguments.done",
    "response.custom_tool_call_input.delta", "response.custom_tool_call_input.done",
    "response.reasoning_text.delta", "response.reasoning_text.done",
    "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
    "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
    "response.content_part.added", "response.content_part.done", "response.refusal.delta",
    "response.refusal.done",
  ]

  init(
    event: JSONValue, model: SingleIdentityConfiguration.Model, functionNames: Set<String>,
    customToolNames: Set<String> = [], expectedPreviousResponseID: String? = nil,
    allowCompaction: Bool = false, allowImages: Bool = false
  )
    throws
  {
    guard let type = event["type"]?.string else {
      throw GatewayProtocolError(502, "unsupported_upstream_event", detail: .upstreamEvent)
    }
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
          || ((try? ClientTools(response["tools"])) != nil
            && (allowImages
              || !(response["tools"]?.array?.contains { $0["type"]?.string == "image_generation" }
                ?? false)))
      else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      if let previous = response["previous_response_id"], previous != .null {
        guard previous.string == expectedPreviousResponseID, expectedPreviousResponseID != nil
        else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
      }
      try Self.validateUsageContainer(response["usage"])
      if let error = response["error"], error != .null {
        throw GatewayProtocolError(502, "upstream_execution_failed")
      }
      for key in [
        "status", "model", "object", "service_tier", "instructions", "prompt_cache_key",
        "prompt_cache_retention", "previous_response_id",
      ] {
        if let value = response[key], value != .null, value.string == nil {
          throw GatewayProtocolError(502, "unsupported_upstream_object")
        }
      }
      for key in ["background", "parallel_tool_calls"] {
        if let value = response[key], value != .null, value.bool == nil {
          throw GatewayProtocolError(502, "unsupported_upstream_object")
        }
      }
      if let created = response["created_at"], created.integer == nil {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      if let details = response["incomplete_details"], details != .null {
        guard details["reason"]?.string != nil,
          details.object?.keys.allSatisfy({ $0 == "reason" }) == true
        else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
      }
      bindings.append(.init(type: "response", rawID: id))
      if allowCompaction, type == "response.completed" {
        guard let output = response["output"]?.array,
          output.filter({ $0["type"]?.string == "compaction" }).count == 1
        else { throw GatewayProtocolError(502, "invalid_upstream_compaction") }
      }
      if let output = response["output"]?.array {
        guard output.count <= 16 else {
          throw GatewayProtocolError(502, "upstream_output_too_large")
        }
        for item in output {
          bindings += try Self.itemBindings(
            item, functionNames: functionNames, customToolNames: customToolNames,
            allowCompaction: allowCompaction, allowImages: allowImages)
        }
      }
      if terminal { usage = try Self.usage(response["usage"], model: model) }
    } else if itemEvents.contains(type), let item = event["item"] {
      bindings += try Self.itemBindings(
        item, functionNames: functionNames, customToolNames: customToolNames,
        allowCompaction: allowCompaction, partialCompaction: type == "response.output_item.added",
        allowImages: allowImages)
    } else if type.hasPrefix("response.image_generation_call."), allowImages {
      guard
        [
          "response.image_generation_call.in_progress", "response.image_generation_call.generating",
          "response.image_generation_call.completed",
          "response.image_generation_call.partial_image",
        ].contains(type),
        let id = event["item_id"]?.string, !id.isEmpty, id.utf8.count <= 256
      else { throw GatewayProtocolError(502, "invalid_upstream_image") }
      if type.hasSuffix("partial_image") {
        guard let index = event["partial_image_index"]?.integer, (0...2).contains(index),
          let encoded = event["partial_image_b64"]?.string,
          encoded.utf8.count <= ImageLimits.eventBytes,
          let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded
        else { throw GatewayProtocolError(502, "invalid_upstream_image") }
      }
      bindings.append(.init(type: "item", rawID: id))
    } else if Self.transparentEvents.contains(type) {
      if let id = event["item_id"]?.string {
        guard !id.isEmpty, id.utf8.count <= 256 else {
          throw GatewayProtocolError(502, "invalid_upstream_response")
        }
        bindings.append(.init(type: "item", rawID: id))
      }
      if ["response.reasoning_text.delta", "response.reasoning_text.done"].contains(type) {
        let text = type.hasSuffix(".delta") ? event["delta"] : event["text"]
        let allowed: Set<String> = [
          "type", "item_id", "output_index", "content_index", "sequence_number",
          type.hasSuffix(".delta") ? "delta" : "text", "obfuscation",
        ]
        guard text?.string != nil, event.object?.keys.allSatisfy(allowed.contains) == true,
          event["item_id"] == nil || event["item_id"]?.string != nil
        else {
          throw GatewayProtocolError(502, "unsupported_upstream_event", detail: .upstreamEvent)
        }
        for key in ["output_index", "content_index", "sequence_number"] {
          if let index = event[key] {
            guard let index = index.integer, (0...1_000_000_000).contains(index) else {
              throw GatewayProtocolError(502, "unsupported_upstream_event", detail: .upstreamEvent)
            }
          }
        }
        if let padding = event["obfuscation"], padding.string == nil {
          throw GatewayProtocolError(502, "unsupported_upstream_event", detail: .upstreamEvent)
        }
      }
      if let part = event["part"] {
        try Self.validatePart(
          part, allowSummary: true,
          allowReasoning: ["response.content_part.added", "response.content_part.done"].contains(
            type))
      }
    } else {
      throw GatewayProtocolError(502, "unsupported_upstream_event", detail: .upstreamEvent)
    }
    self.bindings = bindings
    self.usage = usage
    self.terminal = terminal
  }

  static func itemBindings(
    _ item: JSONValue, functionNames: Set<String>, customToolNames: Set<String> = [],
    retained: Bool = false, allowCompaction: Bool = false, partialCompaction: Bool = false,
    allowImages: Bool = false
  ) throws -> [ObjectBinding] {
    let type = item["type"]?.string ?? (retained && item["role"] != nil ? "message" : "")
    guard
      ["message", "function_call", "custom_tool_call", "reasoning"].contains(type)
        || allowImages && type == "image_generation_call"
        || allowCompaction && type == "compaction"
        || retained
          && ["compaction", "function_call_output", "custom_tool_call_output"].contains(type)
    else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
    guard !allowCompaction || !["function_call", "custom_tool_call"].contains(type) else {
      throw GatewayProtocolError(502, "unsupported_upstream_object")
    }
    let fields: [String: Set<String>] = [
      "image_generation_call": [
        "result", "revised_prompt", "size", "quality", "background", "output_format", "usage",
        "action",
      ],
      "message": ["role", "content", "phase"],
      "function_call": ["name", "namespace", "arguments", "call_id"],
      "custom_tool_call": ["name", "namespace", "input", "call_id"],
      "function_call_output": ["name", "namespace", "output", "call_id"],
      "custom_tool_call_output": ["name", "namespace", "output", "call_id"],
      "reasoning": ["summary", "content", "encrypted_content"], "compaction": ["encrypted_content"],
    ]
    let allowed = fields[type, default: []].union(["type", "id", "status"])
    guard item.object?.keys.allSatisfy(allowed.contains) == true else {
      throw GatewayProtocolError(502, "unsupported_upstream_object", detail: .upstreamItemMembers)
    }
    var bindings: [ObjectBinding] = []
    if let status = item["status"], status != .null {
      guard
        ["in_progress", "completed", "incomplete", "failed", "cancelled"].contains(
          status.string ?? "")
      else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
    }
    if let name = item["name"], name != .null {
      guard let name = name.string, (try? ClientTools.key(name: name)) != nil else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
    }
    if let namespace = item["namespace"], namespace != .null {
      guard let namespace = namespace.string,
        (try? ClientTools.key(name: item["name"]?.string ?? "output", namespace: namespace)) != nil
      else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
    }
    if let id = item["id"] {
      guard let id = id.string, !id.isEmpty, id.utf8.count <= 256 else {
        throw GatewayProtocolError(502, "invalid_upstream_response")
      }
      bindings.append(.init(type: "item", rawID: id))
    } else if !retained && !(allowCompaction && type == "compaction") {
      throw GatewayProtocolError(502, "invalid_upstream_response")
    }
    if type == "image_generation_call" {
      if item["status"]?.string == "completed" { _ = try imageResult(item) }
      try Self.validateUsageContainer(item["usage"])
      for key in ["revised_prompt", "size", "quality", "background", "output_format", "action"] {
        if let value = item[key], value.string == nil {
          throw GatewayProtocolError(502, "invalid_upstream_image")
        }
      }
    }
    if type == "message" {
      guard let role = item["role"]?.string,
        (retained ? ["user", "assistant", "developer", "system"] : ["assistant"]).contains(role)
      else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
      if !(retained && item["content"]?.string != nil) {
        guard let content = item["content"]?.array, content.count <= 128 else {
          throw GatewayProtocolError(502, "unsupported_upstream_object")
        }
        for part in content {
          if retained && part["type"]?.string == "input_text" {
            guard part["text"]?.string != nil,
              part.object?.keys.allSatisfy({ ["type", "text"].contains($0) }) == true
            else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
          } else {
            try Self.validatePart(part, allowSummary: false)
          }
        }
      }
      if let phase = item["phase"], phase != .null {
        guard ["analysis", "commentary", "final_answer"].contains(phase.string ?? "") else {
          throw GatewayProtocolError(
            502, "unsupported_upstream_object", detail: .upstreamMessagePhase)
        }
      }
    }
    if ["function_call", "custom_tool_call"].contains(type) {
      guard let name = item["name"]?.string,
        item["namespace"] == nil || item["namespace"]?.string != nil,
        let key = try? ClientTools.key(name: name, namespace: item["namespace"]?.string),
        (type == "function_call" ? functionNames : customToolNames).contains(key),
        (type == "function_call" ? item["arguments"]?.string : item["input"]?.string) != nil,
        let call = item["call_id"]?.string, !call.isEmpty, call.utf8.count <= 256
      else { throw GatewayProtocolError(502, "invalid_upstream_response") }
      bindings.append(.init(type: "function_call", rawID: call))
    }
    if ["function_call_output", "custom_tool_call_output"].contains(type) {
      guard let call = item["call_id"]?.string, !call.isEmpty, call.utf8.count <= 256,
        item["output"]?.string != nil
      else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
      bindings.append(.init(type: "function_call", rawID: call))
    }
    if type == "reasoning", let content = item["content"], content != .null {
      guard let parts = content.array, parts.count <= 128,
        parts.allSatisfy({
          $0["type"]?.string == "reasoning_text" && $0["text"]?.string != nil
            && $0.object?.keys.allSatisfy({ ["type", "text"].contains($0) }) == true
        })
      else { throw GatewayProtocolError(502, "unsupported_upstream_object") }
    }
    if let summary = item["summary"] {
      guard type == "reasoning", let parts = summary.array, parts.count <= 128 else {
        throw GatewayProtocolError(502, "unsupported_upstream_object")
      }
      for part in parts { try Self.validatePart(part, allowSummary: true) }
    }
    if ["reasoning", "compaction"].contains(type) {
      if type == "compaction", allowCompaction, partialCompaction,
        item["encrypted_content"] == nil || item["encrypted_content"] == .null
          || item["encrypted_content"] == .string("")
      {
        return bindings
      }
      do {
        if let binding = try opaqueContext(item["encrypted_content"], kind: type) {
          bindings.append(binding)
        } else if type == "compaction" {
          throw GatewayProtocolError(502, "unsupported_upstream_object")
        }
      } catch { throw GatewayProtocolError(502, "unsupported_upstream_object") }
    }
    return bindings
  }

  private static func validatePart(
    _ part: JSONValue, allowSummary: Bool, allowReasoning: Bool = false
  ) throws {
    let type = part["type"]?.string ?? ""
    let allowedTypes =
      (allowSummary ? ["output_text", "refusal", "summary_text"] : ["output_text", "refusal"])
      + (allowReasoning ? ["reasoning_text"] : [])
    let text = type == "refusal" ? part["refusal"]?.string : part["text"]?.string
    let keys: Set<String> =
      type == "output_text"
      ? ["type", "text", "annotations", "logprobs"]
      : type == "refusal" ? ["type", "refusal"] : ["type", "text"]
    guard allowedTypes.contains(type), text != nil,
      part["annotations"] == nil || part["annotations"]?.array == [],
      part["logprobs"] == nil || part["logprobs"] == .null || part["logprobs"]?.array == [],
      part.object?.keys.allSatisfy(keys.contains) == true
    else {
      throw GatewayProtocolError(502, "unsupported_upstream_object", detail: .upstreamPart)
    }
  }

  static func validateUsageContainer(_ value: JSONValue?) throws {
    guard let value, value != .null else { return }
    func numeric(_ value: JSONValue) -> Bool {
      if value == .null { return true }
      if case .number = value { return true }
      return false
    }
    guard let object = value.object, object.count <= 32,
      object.values.allSatisfy({ value in
        if numeric(value) { return true }
        return value.object.map { $0.count <= 32 && $0.values.allSatisfy(numeric) } == true
      })
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
