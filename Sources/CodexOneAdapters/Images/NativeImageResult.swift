import Foundation

/// Complete native JSON results only: never convert error documents or partial output into success.
enum NativeImageResult {
  static func decode(_ data: Data) throws -> JSONValue {
    guard let document = try? JSONValue.decode(data) else {
      throw GatewayProtocolError(502, "invalid_upstream_image")
    }
    return try validated(document)
  }

  static func validated(_ document: JSONValue) throws -> JSONValue {
    try requireCompletion(document)
    guard document.object != nil,
      document["error"] == nil, document["type"] == nil,
      let created = document["created"]?.integer, created >= 0,
      let items = document["data"]?.array, !items.isEmpty,
      items.allSatisfy({ item in
        guard item.object != nil, item["error"] == nil,
          let encoded = item["b64_json"]?.string,
          let bytes = Data(base64Encoded: encoded), !bytes.isEmpty
        else { return false }
        return bytes.base64EncodedString() == encoded
      })
    else { throw GatewayProtocolError(502, "invalid_upstream_image") }
    return document
  }

  static func requireCompletion(_ document: JSONValue) throws {
    guard let status = document["status"] else { return }
    guard status.string == "completed" else {
      if ["failed", "cancelled"].contains(status.string ?? "") {
        throw GatewayProtocolError(502, "upstream_execution_failed")
      }
      throw GatewayProtocolError(502, "execution_indeterminate")
    }
  }

  /// Native completion metadata lives at the result level; image payload lives in data.
  /// Require the provider timestamp rather than inventing a gateway timestamp.
  static func assembled(_ terminal: JSONValue) throws -> JSONValue {
    guard var fields = terminal.object else {
      throw GatewayProtocolError(502, "invalid_upstream_image")
    }
    fields.removeValue(forKey: "type")
    if fields["data"] == nil {
      guard let image = fields.removeValue(forKey: "b64_json"),
        let created = fields.removeValue(forKey: "created_at")
      else { throw GatewayProtocolError(502, "invalid_upstream_image") }
      var item: JSONObject = ["b64_json": image]
      if let revised = fields.removeValue(forKey: "revised_prompt") {
        item["revised_prompt"] = revised
      }
      // Match the native non-stream envelope order without dropping future result metadata.
      var result: JSONObject = ["created": created, "data": .array([.object(item)])]
      for (key, value) in fields { result[key] = value }
      return try validated(.object(result))
    }
    return try validated(.object(fields))
  }

  static func completions(_ document: JSONValue, editing: Bool) -> [JSONValue] {
    let items = document["data"]!.array!
    return items.enumerated().map { index, item in
      var fields = document.object!
      fields.removeValue(forKey: "data")
      fields.removeValue(forKey: "created")
      // Aggregate usage belongs only to the last completion, never once per image.
      if index != items.count - 1 { fields.removeValue(forKey: "usage") }
      for (key, value) in item.object! { fields[key] = value }
      fields["created_at"] = document["created"]
      fields["type"] = .string(editing ? "image_edit.completed" : "image_generation.completed")
      return .object(fields)
    }
  }
}
