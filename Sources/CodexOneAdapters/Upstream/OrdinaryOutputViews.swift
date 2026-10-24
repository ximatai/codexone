import Crypto
import Foundation

/// One ordinary execution's bounded correlation state. Text/ciphertext survives only as hashes.
struct OrdinaryOutputViews {
  private struct TextView {
    var hash = SHA256()
    var count = 0
    var initial: Data?
    var initialCount = 0
    var deltas = false
    var done: Data?

    mutating func start(_ text: String) throws {
      let bytes = Data(text.utf8)
      if deltas || done != nil {
        let expected = done ?? Data(hash.finalize())
        guard Data(SHA256.hash(data: bytes)) == expected else {
          throw OrdinaryOutputViews.failure(.upstreamOutputValue)
        }
        return
      }
      if let initial {
        guard initialCount <= bytes.count,
          Data(SHA256.hash(data: bytes.prefix(initialCount))) == initial
        else { throw OrdinaryOutputViews.failure(.upstreamOutputValue) }
      }
      initial = Data(SHA256.hash(data: bytes))
      initialCount = bytes.count
      hash = SHA256()
      hash.update(data: bytes)
      count = bytes.count
    }
    mutating func append(_ text: String) throws {
      guard done == nil, text.utf8.count <= 8_388_608 - count else {
        throw OrdinaryOutputViews.failure(.upstreamOutputValue)
      }
      hash.update(data: Data(text.utf8))
      count += text.utf8.count
      deltas = true
    }
    mutating func finish(_ text: String) throws {
      let bytes = Data(text.utf8)
      let digest = Data(SHA256.hash(data: bytes))
      if let done, done != digest { throw OrdinaryOutputViews.failure(.upstreamOutputValue) }
      if deltas {
        guard count == bytes.count, Data(hash.finalize()) == digest else {
          throw OrdinaryOutputViews.failure(.upstreamOutputValue)
        }
      } else if let initial {
        guard initialCount <= bytes.count,
          Data(SHA256.hash(data: bytes.prefix(initialCount))) == initial
        else { throw OrdinaryOutputViews.failure(.upstreamOutputValue) }
      }
      done = digest
    }
  }
  private struct Item {
    var id: String?
    var index: Int?
    var identity: [String: String] = [:]
    var fields: [String: TextView] = [:]
    var kinds: [String: String] = [:]
    var counts: [String: Int] = [:]
    var unindexed = Set<String>()
    var finished = false

    mutating func identify(_ document: JSONValue) throws {
      for key in ["type", "role", "call_id", "name", "namespace"] {
        let value =
          document[key]?.string
          ?? (key == "namespace"
            && (document["name"] != nil || document["call_id"] != nil)
            && ["function_call", "custom_tool_call"].contains(document["type"]?.string ?? "")
            ? "" : nil)
        if let value {
          guard identity[key] == nil || identity[key] == value else {
            throw OrdinaryOutputViews.failure(.upstreamOutputIdentity)
          }
          identity[key] = value
        }
      }
    }
    mutating func text(_ key: String, kind: String, value: String, operation: String) throws {
      guard kinds[key] == nil || kinds[key] == kind else {
        throw OrdinaryOutputViews.failure(.upstreamOutputIdentity)
      }
      kinds[key] = kind
      var field = fields[key] ?? TextView()
      switch operation {
      case "start": try field.start(value)
      case "delta":
        guard !finished else { throw OrdinaryOutputViews.failure(.upstreamOutputValue) }
        try field.append(value)
      default: try field.finish(value)
      }
      fields[key] = field
    }
    mutating func parts(_ array: JSONValue?, group: String, complete: Bool) throws {
      guard let parts = array?.array else { return }
      guard parts.count <= 128, !unindexed.contains(group) || parts.count <= 1,
        counts[group] == nil || counts[group] == parts.count
      else {
        throw OrdinaryOutputViews.failure(.upstreamOutputValue)
      }
      for (index, part) in parts.enumerated() {
        guard let kind = part["type"]?.string,
          let value = (kind == "refusal" ? part["refusal"] : part["text"])?.string
        else { throw OrdinaryOutputViews.failure(.upstreamOutputValue) }
        try text(
          "\(group):\(index)", kind: kind, value: value, operation: complete ? "done" : "start")
      }
      if complete {
        for key in fields.keys where key.hasPrefix(group + ":") {
          guard let index = Int(key.dropFirst(group.count + 1)), index < parts.count else {
            throw OrdinaryOutputViews.failure(.upstreamOutputValue)
          }
        }
        counts[group] = parts.count
      }
    }
    mutating func snapshot(_ item: JSONValue, complete: Bool) throws {
      try identify(item)
      for group in ["content", "summary"] {
        try parts(item[group], group: group, complete: complete)
      }
      for key in ["arguments", "input"] {
        if let text = item[key]?.string {
          try self.text(key, kind: key, value: text, operation: complete ? "done" : "start")
        }
      }
      if complete, let cipher = item["encrypted_content"]?.string {
        // Opaque context is compared only when supplied in completed views, never retained in clear.
        try text("encrypted_content", kind: "encrypted_content", value: cipher, operation: "done")
      }
      if complete { finished = true }
    }
  }
  private var items: [Item] = []
  private var unaddressed = false

  private static func failure(_ detail: ProtocolRejectionDetail) -> GatewayProtocolError {
    .init(502, "invalid_upstream_output", detail: detail)
  }
  private mutating func locate(id: String?, index: Int?) throws -> Int {
    if let id {
      guard !id.isEmpty, id.utf8.count <= 256 else { throw Self.failure(.upstreamOutputIdentity) }
    }
    if let index {
      guard (0..<16).contains(index) else { throw Self.failure(.upstreamOutputCapacity) }
    }
    let byID = id.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let byIndex = index.flatMap { index in items.firstIndex(where: { $0.index == index }) }
    guard byID == nil || byIndex == nil || byID == byIndex else {
      throw Self.failure(.upstreamOutputIdentity)
    }
    var found = byID ?? byIndex
    if found == nil, items.count == 1, items[0].id == nil, items[0].index == nil { found = 0 }
    if id == nil && index == nil {
      guard items.count <= 1 else { throw Self.failure(.upstreamOutputIdentity) }
      unaddressed = true
      if !items.isEmpty { found = 0 }
    }
    if found == nil {
      guard items.count < 16 else { throw Self.failure(.upstreamOutputCapacity) }
      items.append(Item())
      found = items.count - 1
    }
    let slot = found!
    guard id == nil || items[slot].id == nil || items[slot].id == id,
      index == nil || items[slot].index == nil || items[slot].index == index
    else { throw Self.failure(.upstreamOutputIdentity) }
    if let id { items[slot].id = id }
    if let index { items[slot].index = index }
    return slot
  }
  private func position(_ value: JSONValue?) throws -> Int? {
    guard let value else { return nil }
    guard let index = value.integer, (0..<16).contains(index) else {
      throw Self.failure(.upstreamOutputCapacity)
    }
    return Int(index)
  }
  private func partIndex(_ value: JSONValue?) throws -> Int {
    guard let value else { return 0 }
    guard let index = value.integer, (0..<128).contains(index) else {
      throw Self.failure(.upstreamOutputCapacity)
    }
    return Int(index)
  }
  private func checkCalls() throws {
    let calls = items.compactMap { $0.identity["call_id"] }
    guard Set(calls).count == calls.count else { throw Self.failure(.upstreamOutputIdentity) }
  }
  mutating func observe(_ event: JSONValue) throws {
    let type = event["type"]?.string ?? ""
    if ["response.output_item.added", "response.output_item.done"].contains(type) {
      guard let item = event["item"] else { throw Self.failure(.upstreamOutputValue) }
      let slot = try locate(id: item["id"]?.string, index: position(event["output_index"]))
      try items[slot].snapshot(item, complete: type.hasSuffix(".done"))
      try checkCalls()
      return
    }
    if [
      "response.created", "response.in_progress", "response.completed", "response.failed",
      "response.incomplete",
    ].contains(type) {
      let complete = type == "response.completed"
      guard let output = event["response"]?["output"]?.array else {
        guard !complete || items.isEmpty else { throw Self.failure(.upstreamOutputValue) }
        return
      }
      guard output.count <= 16, !unaddressed || output.count <= 1 else {
        throw Self.failure(.upstreamOutputCapacity)
      }
      var ids = Set<String>()
      var seen = Set<Int>()
      for (index, item) in output.enumerated() {
        guard let id = item["id"]?.string, ids.insert(id).inserted else {
          throw Self.failure(.upstreamOutputIdentity)
        }
        let slot = try locate(id: id, index: index)
        if complete || items[slot].finished {
          try items[slot].snapshot(item, complete: true)
        } else if ["response.created", "response.in_progress"].contains(type) {
          try items[slot].snapshot(item, complete: item["status"]?.string == "completed")
        } else {
          try items[slot].identify(item)
        }
        seen.insert(slot)
      }
      try checkCalls()
      guard !complete || seen.count == items.count else { throw Self.failure(.upstreamOutputValue) }
      return
    }
    guard ProviderObservation.transparentEvents.contains(type) else { return }
    if let id = event["item_id"], id.string == nil { throw Self.failure(.upstreamOutputIdentity) }
    let slot = try locate(id: event["item_id"]?.string, index: position(event["output_index"]))
    if let call = event["call_id"] {
      guard let id = call.string, !id.isEmpty, id.utf8.count <= 256 else {
        throw Self.failure(.upstreamOutputIdentity)
      }
      try items[slot].identify(.object(["call_id": .string(id)]))
    }
    let isSummary = type.contains("reasoning_summary")
    let isReasoning = isSummary || type.contains("reasoning_text")
    let itemType =
      type.contains("function_call_arguments")
      ? "function_call"
      : type.contains("custom_tool_call_input")
        ? "custom_tool_call"
        : isReasoning
          ? "reasoning" : type.contains("output_text") || type.contains("refusal") ? "message" : nil
    if let itemType { try items[slot].identify(.object(["type": .string(itemType)])) }
    if type.contains("content_part") || type.contains("reasoning_summary_part") {
      guard let part = event["part"] else { throw Self.failure(.upstreamOutputValue) }
      let kind = part["type"]?.string ?? ""
      let group = isSummary ? "summary" : "content"
      try items[slot].identify(
        .object(["type": .string(kind == "reasoning_text" || isSummary ? "reasoning" : "message")]))
      let indexMember = isSummary ? "summary_index" : "content_index"
      if event[indexMember] == nil {
        items[slot].unindexed.insert(isSummary ? "summary" : "content")
      }
      let index = try partIndex(event[indexMember])
      guard let value = (kind == "refusal" ? part["refusal"] : part["text"])?.string else {
        throw Self.failure(.upstreamOutputValue)
      }
      guard !items[slot].finished || items[slot].fields["\(group):\(index)"] != nil else {
        throw Self.failure(.upstreamOutputValue)
      }
      try items[slot].text(
        "\(group):\(index)", kind: kind, value: value,
        operation: type.hasSuffix(".added") ? "start" : "done")
      return
    }
    let key: String
    let kind: String
    if type.contains("function_call_arguments") {
      key = "arguments"
      kind = key
    } else if type.contains("custom_tool_call_input") {
      key = "input"
      kind = key
    } else {
      let indexMember = isSummary ? "summary_index" : "content_index"
      if event[indexMember] == nil {
        items[slot].unindexed.insert(isSummary ? "summary" : "content")
      }
      let index = try partIndex(event[indexMember])
      key = "\(isSummary ? "summary" : "content"):\(index)"
      kind =
        isSummary
        ? "summary_text"
        : isReasoning
          ? "reasoning_text"
          : type.contains("refusal") ? "refusal" : "output_text"
    }
    let delta = type.hasSuffix(".delta")
    let member =
      delta
      ? "delta"
      : kind == "refusal"
        ? "refusal" : key == "arguments" ? "arguments" : key == "input" ? "input" : "text"
    guard let text = event[member]?.string else { throw Self.failure(.upstreamOutputValue) }
    try items[slot].text(key, kind: kind, value: text, operation: delta ? "delta" : "done")
  }
}
