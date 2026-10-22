import Foundation

func imageResult(_ item: JSONValue) throws -> String {
  guard let encoded = item["result"]?.string, !encoded.isEmpty,
    encoded.utf8.count <= ImageLimits.eventBytes,
    let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
  else {
    throw GatewayProtocolError(502, "invalid_upstream_image")
  }
  _ = try ImagePayload(bytes: bytes, maximumBytes: ImageLimits.imageBytes)
  return encoded
}

func imageReply(_ document: JSONValue, streaming: Bool, editing: Bool, options: JSONValue? = nil)
  throws -> JSONValue?
{
  func metadata(_ source: JSONValue, created: JSONValue? = nil) throws -> [String: JSONValue] {
    for key in ["size", "quality", "background", "output_format"] {
      if let value = source[key] {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= 128 else {
          throw GatewayProtocolError(502, "invalid_upstream_image")
        }
      }
    }
    for (key, values) in [
      "quality": ["low", "medium", "high", "xhigh", "max", "auto"],
      "background": ["auto", "transparent", "opaque"], "output_format": ["png", "jpeg", "webp"],
    ] {
      if let value = source[key], !values.contains(value.string ?? "") {
        throw GatewayProtocolError(502, "invalid_upstream_image")
      }
    }
    return [
      "created_at": created ?? .number(Decimal(Int64(Date().timeIntervalSince1970))),
      "size": source["size"] ?? options?["size"] ?? .string("auto"),
      "quality": source["quality"] ?? options?["quality"] ?? .string("auto"),
      "background": source["background"] ?? options?["background"] ?? .string("auto"),
      "output_format": source["output_format"] ?? options?["output_format"] ?? .string("png"),
    ]
  }
  let prefix = editing ? "image_edit" : "image_generation"
  if streaming, document["type"]?.string == "response.image_generation_call.partial_image" {
    guard let encoded = document["partial_image_b64"]?.string,
      let index = document["partial_image_index"]?.integer, (0...2).contains(index),
      encoded.utf8.count <= ImageLimits.eventBytes,
      let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded
    else {
      throw GatewayProtocolError(502, "invalid_upstream_image")
    }
    var partial = try metadata(document)
    partial["type"] = .string(prefix + ".partial_image")
    partial["b64_json"] = .string(encoded)
    partial["partial_image_index"] = .number(Decimal(index))
    return .object(partial)
  }
  let response: JSONValue
  if streaming {
    guard let type = document["type"]?.string else {
      throw GatewayProtocolError(502, "invalid_upstream_response")
    }
    if ["response.failed", "response.incomplete"].contains(type) {
      throw GatewayProtocolError(502, "upstream_execution_failed")
    }
    guard type == "response.completed", let terminal = document["response"] else { return nil }
    response = terminal
  } else {
    response = document
  }
  guard response["status"]?.string == "completed", let output = response["output"]?.array else {
    throw GatewayProtocolError(502, "upstream_execution_failed")
  }
  let images = output.filter { $0["type"]?.string == "image_generation_call" }
  guard images.count == 1, let item = images.first, item["status"]?.string == "completed" else {
    throw GatewayProtocolError(502, "invalid_upstream_image")
  }
  let encoded = try imageResult(item)
  var result: [String: JSONValue] = ["b64_json": .string(encoded)]
  for key in ["revised_prompt"] {
    if let value = item[key] { result[key] = value }
  }
  if streaming {
    result.merge(try metadata(item, created: response["created_at"])) { current, _ in current }
    result["type"] = .string(prefix + ".completed")
    if let usage = item["usage"] { result["usage"] = usage }
    return .object(result)
  }
  var reply = try metadata(item, created: response["created_at"])
  reply["created"] = reply.removeValue(forKey: "created_at")
  reply["data"] = .array([.object(result)])
  if let usage = item["usage"] { reply["usage"] = usage }
  return .object(reply)
}
