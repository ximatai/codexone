import CodexOneCore
import Foundation

/// Only validated author facts cross into the ledger. Raw usage remains client data.
struct SVGUsage {
  let input: Int64?
  let output: Int64?
  let reasoning: Int64?
  let model: String?
  let complete: Bool
  let cost: Int64?
  let reasons: [String]
  let present: Bool

  /// Provider snapshots are cumulative; missing or smaller counters never erase trusted facts.
  static func mergingSnapshot(_ previous: JSONValue?, _ next: JSONValue?) -> JSONValue? {
    guard let next, next != .null else { return previous }
    var fields: JSONObject = [:]
    let old = SVGUsage(.object(["svg_usage": previous ?? .null]), items: [], expected: false)
    let new = SVGUsage(.object(["svg_usage": next]), items: [], expected: true)
    if let a = old.model, let b = new.model, a != b {
      var retained = previous?.object ?? [:]
      retained["_ambiguous"] = .bool(true)
      return .object(retained)
    }
    for (key, a, b) in [
      ("input_tokens", old.input, new.input), ("output_tokens", old.output, new.output),
      ("reasoning_tokens", old.reasoning, new.reasoning),
    ] {
      if let value = [a, b].compactMap({ $0 }).max() { fields[key] = .number(Decimal(value)) }
    }
    let model = new.model ?? old.model
    if let model { fields["model"] = .string(model) }
    if previous?["_ambiguous"] == .bool(true)
      || (old.model != nil && new.model != nil && old.model != new.model)
      || new.reasons.contains("svg_total_inconsistent")
    {
      fields["_ambiguous"] = .bool(true)
    }
    return .object(fields)
  }

  init(
    _ document: JSONValue?, items: [JSONValue], expected: Bool,
    models: [SingleIdentityConfiguration.Model] = []
  ) {
    let root = document?["svg_usage"]
    let entries: [JSONValue]
    if let root, root != .null {
      entries = [root]
    } else {
      entries = items.compactMap { value in
        guard let usage = value["svg_usage"], usage != .null else { return nil }
        return usage
      }
    }
    let ambiguous =
      entries.contains { $0["_ambiguous"] == .bool(true) } || entries.count > 1
      || ((root == nil || root == .null) && items.count > 1 && !entries.isEmpty)
    present = expected || !entries.isEmpty
    func count(_ value: JSONValue?) -> Int64? {
      guard let n = value?.integer, (0...1_000_000_000).contains(n) else { return nil }
      return n
    }
    let input = entries.compactMap { count($0["input_tokens"]) }.max()
    let output = entries.compactMap { count($0["output_tokens"]) }.max()
    self.input = input
    self.output = output
    let observedReasoning = entries.compactMap { count($0["reasoning_tokens"]) }.max()
    reasoning = observedReasoning.flatMap { n in output.map { n <= $0 ? n : nil } ?? nil }
    let names = Set(
      entries.compactMap { entry -> String? in
        guard let name = entry["model"]?.string, !name.isEmpty, name.utf8.count <= 128,
          name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0)
              || (97...122).contains($0) || [45, 46, 47, 58, 95].contains($0)
          })
        else { return nil }
        return name
      })
    let model = names.count == 1 ? names.first : nil
    self.model = model
    var reasons: [String] = []
    if present && input == nil { reasons.append("svg_input_unavailable") }
    if present && output == nil { reasons.append("svg_output_unavailable") }
    if ambiguous { reasons.append("svg_usage_ambiguous") }
    let consistentTotal = entries.allSatisfy { entry in
      guard let total = entry["total_tokens"], total != .null else { return true }
      guard let i = count(entry["input_tokens"]), let o = count(entry["output_tokens"]) else {
        return false
      }
      return total.integer == i + o
    }
    if !consistentTotal { reasons.append("svg_total_inconsistent") }
    complete =
      !present
      || (entries.count == 1 && !ambiguous && input != nil && output != nil && consistentTotal)
    if present, let mapping = models.first(where: { $0.id == model }) {
      cost = imageCost(
        input: input, output: output, inputRate: mapping.inputMicrosPerMillion,
        outputRate: mapping.outputMicrosPerMillion)
    } else {
      cost = present ? nil : 0
    }
    if present && cost == nil { reasons.append("svg_price_unavailable") }
    self.reasons = reasons
  }
}

/// A bounded estimate, independent from availability of the token counters themselves.
func imageCost(input: Int64?, output: Int64?, inputRate: Int64, outputRate: Int64) -> Int64? {
  guard input != nil || output != nil else { return nil }
  let raw =
    (Decimal(input ?? 0) * Decimal(inputRate) + Decimal(output ?? 0) * Decimal(outputRate))
    / 1_000_000
  var value = raw
  var rounded = Decimal()
  NSDecimalRound(&rounded, &value, 0, .up)
  guard !rounded.isNaN, rounded >= 0 else {
    return nil
  }
  return NSDecimalNumber(decimal: min(rounded, Decimal(1_000_000_000_000 as Int64))).int64Value
}
