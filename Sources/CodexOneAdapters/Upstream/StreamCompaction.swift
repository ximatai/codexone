import CodexOneCore

/// A streamed compaction has one completed opaque item; event and terminal views must agree.
struct StreamCompaction {
  private var added = false
  private var index: Int64?
  private var objectID: String?
  private var completed: ObjectBinding?

  mutating func observe(_ event: JSONValue) throws {
    let type = event["type"]?.string ?? ""
    if ["response.output_item.added", "response.output_item.done"].contains(type),
      let item = event["item"], item["type"]?.string == "compaction"
    {
      guard let position = event["output_index"]?.integer, (0..<256).contains(position),
        index == nil || index == position, completed == nil,
        objectID == nil || item["id"]?.string == objectID
      else { throw GatewayProtocolError(502, "invalid_upstream_compaction") }
      index = position
      objectID = item["id"]?.string
      if type == "response.output_item.added" {
        guard !added else { throw GatewayProtocolError(502, "invalid_upstream_compaction") }
        added = true
      } else {
        completed = try fingerprint(item)
      }
    }
    if type == "response.completed" {
      guard let output = event["response"]?["output"]?.array else {
        throw GatewayProtocolError(502, "invalid_upstream_compaction")
      }
      let items = output.filter { $0["type"]?.string == "compaction" }
      guard items.count == 1, completed != nil,
        objectID == nil || items[0]["id"]?.string == objectID
      else { throw GatewayProtocolError(502, "invalid_upstream_compaction") }
      let final = try fingerprint(items[0])
      guard completed == final else {
        throw GatewayProtocolError(502, "invalid_upstream_compaction")
      }
    }
  }

  private func fingerprint(_ item: JSONValue) throws -> ObjectBinding {
    do {
      guard let binding = try opaqueContext(item["encrypted_content"], kind: "compaction") else {
        throw GatewayProtocolError(502, "invalid_upstream_compaction")
      }
      return binding
    } catch { throw GatewayProtocolError(502, "invalid_upstream_compaction") }
  }
}
