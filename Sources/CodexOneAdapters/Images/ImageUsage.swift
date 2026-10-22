import CodexOneCore
import Foundation

extension ResponseRequest {
  func observeUsage(
    _ response: JSONValue?, context: ExecutionContext,
    model: SingleIdentityConfiguration.Model, configuration: ImageConfiguration?
  ) throws {
    if requirements.imageModel != nil,
      let host = try ProviderObservation.usage(response?["usage"], model: model)
    {
      // Host evidence survives malformed or unavailable tool metrics; only the combined revision can settle.
      try context.observeUsage(
        .init(
          revision: 0, inputTokens: host.inputTokens, outputTokens: host.outputTokens,
          cachedTokens: host.cachedTokens, images: 0, estimatedMicros: host.estimatedMicros,
          completeness: .partial))
    }
    if let evidence = try usage(response, model: model, configuration: configuration) {
      try context.observeUsage(evidence)
    }
  }

  /// Host response usage and tool usage stay separate; no tool tokens are added to host totals.
  func usage(
    _ response: JSONValue?, model: SingleIdentityConfiguration.Model,
    configuration: ImageConfiguration?
  ) throws -> UsageEvidence? {
    let host = try ProviderObservation.usage(response?["usage"], model: model)
    guard let imageModel = requirements.imageModel else { return host }
    guard let mapping = configuration?.models.first(where: { $0.id == imageModel }) else {
      throw GatewayProtocolError(502, "invalid_upstream_image")
    }
    let outputItems = response?["output"]?.array
    let items = outputItems?.filter { $0["type"]?.string == "image_generation_call" } ?? []
    guard items.count <= 16 else { throw GatewayProtocolError(502, "upstream_output_too_large") }
    var input: Int64 = 0
    var output: Int64 = 0
    let knownOutputItems =
      outputItems?.allSatisfy {
        ["message", "reasoning", "function_call", "custom_tool_call", "image_generation_call"]
          .contains($0["type"]?.string ?? "")
      } == true && (!items.isEmpty || response?["status"]?.string == "completed")
    var knownInput = knownOutputItems
    var knownOutput = knownOutputItems
    var images: Int64 = 0
    var complete = knownOutputItems
    for item in items {
      func tokens(_ name: String) throws -> Int64? {
        guard let value = item["usage"]?[name], value != .null else { return nil }
        guard let number = value.integer, (0...1_000_000_000).contains(number) else {
          throw GatewayProtocolError(502, "invalid_upstream_usage")
        }
        return number
      }
      let i = try tokens("input_tokens")
      let o = try tokens("output_tokens")
      input += i ?? 0
      output += o ?? 0
      knownInput = knownInput && i != nil
      knownOutput = knownOutput && o != nil
      if item["status"]?.string == "completed", item["result"]?.string != nil {
        images += 1
      } else {
        complete = false
      }
    }
    let toolCost =
      Decimal(input) * Decimal(mapping.inputMicrosPerMillion) + Decimal(output)
      * Decimal(mapping.outputMicrosPerMillion)
    let rounded = NSDecimalNumber(decimal: toolCost / 1_000_000).rounding(
      accordingToBehavior: NSDecimalNumberHandler(
        roundingMode: .up, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
        raiseOnUnderflow: false, raiseOnDivideByZero: false)
    ).int64Value
    guard rounded >= 0, rounded <= 1_000_000_000_000 - (host?.estimatedMicros ?? 0) else {
      throw GatewayProtocolError(502, "invalid_upstream_usage")
    }
    return .init(
      revision: 1, inputTokens: host?.inputTokens ?? 0, outputTokens: host?.outputTokens ?? 0,
      cachedTokens: host?.cachedTokens ?? 0, images: images,
      estimatedMicros: (host?.estimatedMicros ?? 0) + rounded,
      completeness: complete && knownInput && knownOutput && host?.completeness == .complete
        ? .complete : .partial,
      imageInputTokens: knownInput ? input : nil, imageOutputTokens: knownOutput ? output : nil)
  }
}
