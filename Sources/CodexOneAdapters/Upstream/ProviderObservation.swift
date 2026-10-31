import CodexOneCore
import Foundation

/// Provider-specific evidence extraction; downstream documents are never used as execution proof.
/// Only identities, usage and terminal state are interpreted. Every other member is the provider's
/// contract with the client and is forwarded unchanged, so new shapes never fail an execution.
struct ProviderObservation: Sendable {
  static let maximumTextEventBytes = 8_388_608
  static let maximumTextResponseBytes = 33_554_432
  static let lifecycleEvents: Set<String> = [
    "response.created", "response.queued", "response.in_progress", "response.completed",
    "response.failed", "response.incomplete",
  ]
  static let terminalEvents: Set<String> = [
    "response.completed", "response.failed", "response.incomplete",
  ]
  let bindings: [ObjectBinding]
  let usage: UsageEvidence?
  let terminal: Bool
  let actualServiceTier: String?

  /// Event names are forwarded as SSE event lines, so they stay bounded and line-safe.
  static func eventType(_ event: JSONValue) throws -> String {
    guard let type = event["type"]?.string, (1...128).contains(type.utf8.count),
      type.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      })
    else { throw GatewayProtocolError(502, "invalid_upstream_event", detail: .upstreamEvent) }
    return type
  }

  /// A provider `error` event ends the turn with the provider's own actionable error.
  static func providerFailure(_ event: JSONValue) -> GatewayProtocolError {
    let status = event["status"]?.integer ?? event["status_code"]?.integer
    return ProviderError.failure(
      status: status.map(Int.init), error: event["error"] ?? event)
  }

  init(event: JSONValue, model: SingleIdentityConfiguration.Model, allowImages: Bool = false)
    throws
  {
    let type = try Self.eventType(event)
    var bindings: [ObjectBinding] = []
    var usage: UsageEvidence?
    let terminal = Self.terminalEvents.contains(type)
    if Self.lifecycleEvents.contains(type) {
      guard let response = event["response"], let id = Self.identifier(response["id"]) else {
        throw GatewayProtocolError(502, "invalid_upstream_response")
      }
      bindings.append(.init(type: "response", rawID: id))
      for item in response["output"]?.array ?? [] {
        bindings += try Self.itemBindings(item, allowImages: allowImages)
      }
      if terminal { usage = Self.usage(response["usage"], model: model) }
    } else if let item = event["item"] {
      bindings += try Self.itemBindings(item, allowImages: allowImages)
    } else if allowImages, type == "response.image_generation_call.partial_image" {
      guard let index = event["partial_image_index"]?.integer, (0...2).contains(index),
        let encoded = event["partial_image_b64"]?.string,
        encoded.utf8.count <= ImageLimits.eventBytes,
        let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded
      else { throw GatewayProtocolError(502, "invalid_upstream_image") }
    }
    if let id = Self.identifier(event["item_id"]) {
      bindings.append(.init(type: "item", rawID: id))
    }
    self.bindings = bindings
    self.usage = usage
    self.terminal = terminal
    self.actualServiceTier =
      terminal ? requestMetadataValue(event["response"]?["service_tier"]) : nil
  }

  static func identifier(_ value: JSONValue?) -> String? {
    guard let id = value?.string, !id.isEmpty, id.utf8.count <= 256 else { return nil }
    return id
  }

  /// Item identities, call identities and opaque context fingerprints become owned objects.
  static func itemBindings(_ item: JSONValue, allowImages: Bool = false) throws
    -> [ObjectBinding]
  {
    var bindings: [ObjectBinding] = []
    let type = item["type"]?.string ?? ""
    if let id = identifier(item["id"]) { bindings.append(.init(type: "item", rawID: id)) }
    if let call = identifier(item["call_id"]) {
      bindings.append(.init(type: "function_call", rawID: call))
    }
    if ["reasoning", "compaction"].contains(type),
      let context = try? opaqueContext(item["encrypted_content"], kind: type)
    {
      bindings.append(context)
    }
    if allowImages, type == "image_generation_call", item["status"]?.string == "completed" {
      _ = try imageResult(item)
    }
    return bindings
  }

  /// Project only documented token counters and sanitize provider errors before client output.
  static func textOutput(_ value: JSONValue) -> JSONValue {
    guard var object = value.object else { return value }
    if let response = object["response"] { object["response"] = textOutput(response) }
    if let error = object["error"], error != .null {
      object["error"] = ProviderError.sanitized(error) ?? .object([:])
    }
    if let usage = object["usage"]?.object {
      let root: Set<String> = [
        "input_tokens", "output_tokens", "total_tokens", "input_tokens_details",
        "output_tokens_details",
      ]
      // Clients decode these as integers; malformed counters are dropped rather than forwarded.
      func counter(_ value: JSONValue) -> Bool { value.integer.map { $0 >= 0 } == true }
      var counters = usage.filter { root.contains($0.key) && counter($0.value) }
      for key in ["input_tokens_details", "output_tokens_details"] {
        if let details = usage[key]?.object {
          let known: Set<String> =
            key == "input_tokens_details"
            ? ["cached_tokens", "cache_write_tokens"] : ["reasoning_tokens"]
          counters[key] = .object(details.filter { known.contains($0.key) && counter($0.value) })
        }
      }
      object["usage"] = .object(counters)
    }
    return .object(object)
  }

  /// Malformed counters yield no evidence for that counter; they never fail delivered output.
  static func usage(_ value: JSONValue?, model: SingleIdentityConfiguration.Model)
    -> UsageEvidence?
  {
    guard let value, value != .null else { return nil }
    func count(_ value: JSONValue?) -> Int64? {
      guard let number = value?.integer, (0...1_000_000_000).contains(number) else { return nil }
      return number
    }
    let observedInput = count(value["input_tokens"])
    let observedOutput = count(value["output_tokens"])
    var cached = count(value["input_tokens_details"]?["cached_tokens"])
    if let observedInput, let value = cached, value > observedInput { cached = nil }
    guard observedInput != nil || observedOutput != nil || cached != nil else { return nil }
    let input = max(observedInput ?? 0, cached ?? 0)
    let output = observedOutput ?? 0
    // Configured list-price estimate, explicitly unrelated to subscription window balance.
    let inputCost = input.multipliedReportingOverflow(by: model.inputMicrosPerMillion)
    let outputCost = output.multipliedReportingOverflow(by: model.outputMicrosPerMillion)
    let total = inputCost.partialValue.addingReportingOverflow(outputCost.partialValue)
    guard !inputCost.overflow, !outputCost.overflow, !total.overflow else { return nil }
    let micros = total.partialValue / 1_000_000 + (total.partialValue % 1_000_000 == 0 ? 0 : 1)
    return .init(
      revision: 1, inputTokens: input, outputTokens: output, cachedTokens: cached ?? 0,
      images: 0, estimatedMicros: micros,
      completeness: observedInput != nil && observedOutput != nil && cached != nil
        ? .complete : .partial)
  }
}
