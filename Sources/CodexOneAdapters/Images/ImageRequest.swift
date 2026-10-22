import CodexOneCore
import Foundation

/// Limits apply before decoding and are shared by JSON, multipart and WS.
enum ImageLimits {
  static let requestBytes = 8_388_608
  static let imageBytes = 4_194_304
  static let totalImageBytes = 6_291_456
  static let eventBytes = 8_388_608
  static let responseBytes = 33_554_432
}

struct ImageToolRequest: Sendable {
  let model: ImageConfiguration.Model
  let document: JSONValue
  init(_ value: JSONValue, configuration: ImageConfiguration?, host: String? = nil) throws {
    guard var fields = value.object, fields["type"]?.string == "image_generation",
      fields["model"] == nil || fields["model"]?.string != nil,
      let configuration,
      let model = configuration.models.first(where: {
        $0.id == (fields["model"]?.string ?? configuration.defaultModel)
      }), host == nil || model.hostModel == host
    else { throw GatewayProtocolError(400, "unsupported_image_model") }
    let allowed: Set<String> = [
      "type", "model", "size", "quality", "background", "output_format",
      "output_compression", "moderation", "input_fidelity", "action", "partial_images",
      "input_image_mask",
    ]
    guard fields.keys.allSatisfy(allowed.contains) else {
      throw GatewayProtocolError(400, "unsupported_image_parameter")
    }
    for (name, values) in [
      "quality": ["auto", "low", "medium", "high"],
      "background": ["auto", "opaque", "transparent"],
      "output_format": ["png", "jpeg", "webp"], "moderation": ["auto", "low"],
      "input_fidelity": ["low", "high"], "action": ["auto", "generate", "edit"],
    ] {
      if let value = fields[name], !values.contains(value.string ?? "") {
        throw GatewayProtocolError(400, "unsupported_image_parameter")
      }
    }
    if let size = fields["size"], !model.accepts(size: size.string ?? "") {
      throw GatewayProtocolError(400, "unsupported_image_size")
    }
    guard
      fields["background"]?.string != "transparent"
        || (model.supportsTransparency && fields["output_format"]?.string != "jpeg"),
      fields["input_fidelity"] == nil || model.supportsInputFidelity
    else { throw GatewayProtocolError(400, "unsupported_image_parameter") }
    if let value = fields["output_compression"] {
      guard let n = value.integer, (0...100).contains(n),
        ["jpeg", "webp"].contains(fields["output_format"]?.string ?? "png")
      else { throw GatewayProtocolError(400, "unsupported_image_parameter") }
    }
    if let value = fields["partial_images"] {
      guard let n = value.integer, (0...3).contains(n) else {
        throw GatewayProtocolError(400, "unsupported_image_parameter")
      }
    }
    fields["model"] = .string(model.id)
    self.model = model
    document = .object(fields)
  }
}

struct ImagesRequest: Sendable {
  let response: ResponseRequest
  let streaming: Bool
  let editing: Bool
  init(data: Data, contentType: String, editing: Bool, configuration: ImageConfiguration?) throws {
    guard data.count <= ImageLimits.requestBytes else {
      throw GatewayProtocolError(413, "request_too_large")
    }
    var fields: [String: JSONValue]
    var images: [ImagePayload] = []
    var mask: ImagePayload?
    if contentType.lowercased().hasPrefix("multipart/form-data") {
      guard editing else { throw GatewayProtocolError(415, "unsupported_content_type") }
      fields = [:]
      for part in try imageMultipart(data, contentType: contentType) {
        if ["image", "image[]", "mask"].contains(part.name) {
          let image = try ImagePayload(
            bytes: part.data, declaredType: part.contentType, maximumBytes: ImageLimits.imageBytes)
          if part.name == "mask" {
            guard mask == nil else { throw GatewayProtocolError(400, "invalid_mask") }
            mask = image
          } else {
            images.append(image)
          }
        } else {
          guard fields[part.name] == nil, part.data.count <= 32_768,
            let text = String(data: part.data, encoding: .utf8)
          else { throw GatewayProtocolError(400, "invalid_multipart") }
          if ["n", "partial_images", "output_compression"].contains(part.name) {
            guard let number = Int64(text), String(number) == text else {
              throw GatewayProtocolError(400, "invalid_request")
            }
            fields[part.name] = .number(Decimal(number))
          } else if part.name == "stream" {
            guard ["true", "false"].contains(text) else {
              throw GatewayProtocolError(400, "invalid_request")
            }
            fields[part.name] = .bool(text == "true")
          } else {
            fields[part.name] = .string(text)
          }
        }
      }
    } else {
      guard contentType.lowercased().hasPrefix("application/json"),
        let object = try JSONValue.decode(data).object
      else { throw GatewayProtocolError(400, "invalid_json") }
      fields = object
      if let input = fields.removeValue(forKey: "images") {
        guard editing, let items = input.array, items.count <= 4 else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        for item in items {
          guard item.object?.count == 1, let url = item["image_url"]?.string else {
            throw GatewayProtocolError(400, "invalid_image")
          }
          images.append(try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes))
        }
      }
      if let input = fields.removeValue(forKey: "mask") {
        guard editing, input.object?.count == 1, let url = input["image_url"]?.string else {
          throw GatewayProtocolError(400, "invalid_mask")
        }
        mask = try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes)
      }
    }
    guard let prompt = fields.removeValue(forKey: "prompt")?.string, !prompt.isEmpty,
      prompt.utf8.count <= 32_768, images.count <= 4, editing ? !images.isEmpty : images.isEmpty,
      images.reduce(0, { $0 + $1.bytes.count }) + (mask?.bytes.count ?? 0)
        <= ImageLimits.totalImageBytes,
      images.reduce(0, { $0 + $1.width * $1.height }) <= 33_554_432
    else { throw GatewayProtocolError(400, "invalid_image_request") }
    if let format = fields.removeValue(forKey: "response_format"), format.string != "b64_json" {
      throw GatewayProtocolError(400, "unsupported_response_format")
    }
    if let count = fields.removeValue(forKey: "n"), count.integer != 1 {
      throw GatewayProtocolError(400, "unsupported_image_count")
    }
    let stream = fields.removeValue(forKey: "stream")
    guard stream == nil || stream?.bool != nil else {
      throw GatewayProtocolError(400, "invalid_request")
    }
    streaming = stream?.bool == true
    self.editing = editing
    fields["type"] = .string("image_generation")
    if fields["action"] == nil { fields["action"] = .string(editing ? "edit" : "generate") }
    if let mask {
      try mask.validateMask(for: images[0])
      fields["input_image_mask"] = .object(["image_url": .string(mask.dataURL)])
    }
    let tool = try ImageToolRequest(.object(fields), configuration: configuration)
    var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(prompt)])]
    content += images.map {
      .object(["type": .string("input_image"), "image_url": .string($0.dataURL)])
    }
    var request = try ResponseRequest(
      data: JSONValue.object([
        "model": .string(tool.model.hostModel),
        "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
        "tools": .array([tool.document]),
        "tool_choice": .object(["type": .string("image_generation")]),
        "stream": .bool(streaming),
      ]).data(), imageConfiguration: configuration)
    request.requirements = try .init(route: .images, imageModel: tool.model.id)
    response = request
  }
}
