import Foundation

/// Complete native JSON results only: never convert error documents or partial output into success.
enum NativeImageResult {
  static func decode(_ data: Data) throws -> JSONValue {
    guard let document = try? JSONValue.decode(data), document.object != nil,
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
