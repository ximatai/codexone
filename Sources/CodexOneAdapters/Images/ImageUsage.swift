import CodexOneCore
import Foundation

extension ResponseRequest {
  func observeUsage(
    _ response: JSONValue?, context: ExecutionContext,
    model: SingleIdentityConfiguration.Model, configuration: ImageConfiguration?,
    authorModels: [SingleIdentityConfiguration.Model] = []
  ) throws {
    if requirements.imageModel != nil,
      let host = ProviderObservation.usage(response?["usage"], model: model)
    {
      // Host evidence survives malformed or unavailable tool metrics; only the combined revision can settle.
      try context.observeUsage(
        .init(
          revision: 0, inputTokens: host.inputTokens, outputTokens: host.outputTokens,
          cachedTokens: host.cachedTokens, images: 0, estimatedMicros: host.estimatedMicros,
          completeness: .partial))
    }
    if let evidence = try usage(
      response, model: model, configuration: configuration, authorModels: authorModels)
    {
      try context.observeUsage(evidence)
    }
  }

  /// Host response usage and tool usage stay separate; no tool tokens are added to host totals.
  func usage(
    _ response: JSONValue?, model: SingleIdentityConfiguration.Model,
    configuration: ImageConfiguration?, authorModels: [SingleIdentityConfiguration.Model] = []
  ) throws -> UsageEvidence? {
    let host = ProviderObservation.usage(response?["usage"], model: model)
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
    // Availability of a subtotal differs from completeness of the whole operation.
    var observedInput = knownOutputItems && items.isEmpty
    var observedOutput = knownOutputItems && items.isEmpty
    var images: Int64 = 0
    let expectsSVG =
      document["tools"]?.array?.contains {
        $0["type"]?.string == "image_generation" && $0["output_format"]?.string == "svg"
      } == true || response?["output_format"]?.string == "svg"
      || items.contains { $0["output_format"]?.string == "svg" }
    let author = SVGUsage(
      response, items: items, expected: expectsSVG && !items.isEmpty, models: authorModels)
    var complete = knownOutputItems && author.complete
    for item in items {
      func tokens(_ name: String) -> Int64? {
        guard let value = item["usage"]?[name], value != .null else { return nil }
        guard let number = value.integer, (0...1_000_000_000).contains(number) else {
          return nil
        }
        return number
      }
      let i = tokens("input_tokens")
      let o = tokens("output_tokens")
      observedInput = observedInput || i != nil
      observedOutput = observedOutput || o != nil
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
    let renderCost = imageCost(
      input: observedInput ? input : nil, output: observedOutput ? output : nil,
      inputRate: mapping.inputMicrosPerMillion, outputRate: mapping.outputMicrosPerMillion)
    let sum = (host?.estimatedMicros ?? 0) + (renderCost ?? 0) + (author.cost ?? 0)
    let costValid = sum <= 1_000_000_000_000
    let priceComplete =
      knownInput && knownOutput && host?.completeness == .complete
      && renderCost != nil && author.cost != nil && author.complete && costValid
      && (renderCost ?? 0) < 1_000_000_000_000 && (author.cost ?? 0) < 1_000_000_000_000
    let price: UsageEvidence.PriceCompleteness =
      priceComplete
      ? .complete
      : (host != nil || renderCost != nil || (author.present && author.cost != nil)
        ? .partial : .unavailable)
    return .init(
      revision: 1, inputTokens: host?.inputTokens ?? 0, outputTokens: host?.outputTokens ?? 0,
      cachedTokens: host?.cachedTokens ?? 0, images: images,
      estimatedMicros: min(sum, 1_000_000_000_000),
      completeness: complete && knownInput && knownOutput && host?.completeness == .complete
        ? .complete : .partial,
      imageInputTokens: observedInput ? input : nil,
      imageOutputTokens: observedOutput ? output : nil,
      svgInputTokens: author.input, svgOutputTokens: author.output,
      svgReasoningTokens: author.reasoning, svgAuthorModel: author.model,
      priceCompleteness: price, usageMissingReasons: author.reasons.isEmpty ? nil : author.reasons)
  }
}
