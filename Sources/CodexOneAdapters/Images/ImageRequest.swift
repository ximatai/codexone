import CodexOneCore
import Foundation

/// Limits apply before decoding and are shared by JSON, multipart and WS.
enum ImageLimits {
  static let imageBytes = 16_777_216
  static let totalImageBytes = 25_165_824
  static let eventBytes = 8_388_608
  static let responseBytes = 33_554_432
  static let nativeResponseBytes = 50_331_648
}

struct ImageToolRequest: Sendable {
  let model: ImageConfiguration.Model
  let document: JSONValue
  init(_ value: JSONValue, configuration: ImageConfiguration?) throws {
    guard var fields = value.object, fields["type"]?.string == "image_generation",
      fields["model"] == nil || fields["model"]?.string != nil,
      let configuration,
      let model = configuration.models.first(where: {
        $0.id == (fields["model"]?.string ?? configuration.defaultModel)
      })
    else { throw GatewayProtocolError(403, "model_not_allowed") }
    // Native Images confirmation says nothing about the Responses hosted tool.
    if let format = fields["output_format"]?.string, !["png", "jpeg", "webp"].contains(format) {
      throw GatewayProtocolError(400, "image_format_not_verified")
    }
    fields["model"] = .string(model.id)
    self.model = model
    document = .object(fields)
  }
}

struct ImagesRequest: Sendable {
  let serviceTier: String?
  let model: String
  let body: Data
  let streaming: Bool
  let editing: Bool
  let verifiedAccountIDs: Set<String>?
  var upstreamStreaming: Bool { !editing && verifiedAccountIDs == nil }
  init(data: Data, contentType: String, editing: Bool, configuration: ImageConfiguration?) throws {
    guard data.count <= RequestBodyLimits.maximumBytes else {
      throw GatewayProtocolError(413, "request_too_large")
    }
    var fields: JSONObject
    let multipart = contentType.lowercased().hasPrefix("multipart/form-data")
    if multipart {
      guard editing else { throw GatewayProtocolError(415, "unsupported_content_type") }
      fields = [:]
      var images: [JSONValue] = []
      for part in try imageMultipart(data, contentType: contentType) {
        if ["image", "image[]", "mask"].contains(part.name) {
          let image = try ImagePayload(
            bytes: part.data, declaredType: part.contentType, maximumBytes: ImageLimits.imageBytes)
          let value = JSONValue.object(["image_url": .string(image.dataURL)])
          if part.name == "mask" {
            guard fields["mask"] == nil else { throw GatewayProtocolError(400, "invalid_mask") }
            fields["mask"] = value
          } else {
            images.append(value)
          }
        } else {
          guard fields[part.name] == nil, part.name != "images", part.data.count <= 32_768,
            let text = String(data: part.data, encoding: .utf8)
          else { throw GatewayProtocolError(400, "invalid_multipart") }
          if ["n", "partial_images", "output_compression"].contains(part.name) {
            guard let number = Int64(text) else {
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
      fields["images"] = .array(images)
    } else {
      guard contentType.lowercased().hasPrefix("application/json") else {
        throw GatewayProtocolError(415, "unsupported_content_type")
      }
      let document: JSONValue
      do {
        document = try JSONValue.decode(
          data,
          rejectingDuplicateRootKeys: [
            "model", "stream", "output_format", "images", "mask", "n", "partial_images",
            "output_compression", "prompt_rewriter",
          ])
      } catch {
        throw GatewayProtocolError(400, "invalid_json")
      }
      guard let object = document.object else { throw GatewayProtocolError(400, "invalid_json") }
      fields = object
    }
    guard fields["model"] == nil || fields["model"]?.string != nil,
      fields["stream"] == nil || fields["stream"]?.bool != nil
    else { throw GatewayProtocolError(400, "invalid_request") }
    guard let model = fields["model"]?.string ?? configuration?.defaultModel,
      configuration?.models.contains(where: { $0.id == model }) == true
    else { throw GatewayProtocolError(403, "model_not_allowed") }
    var total = 0
    if let value = fields["images"] {
      guard let images = value.array, images.count <= 16 else {
        throw GatewayProtocolError(400, "invalid_image")
      }
      for image in images {
        guard let url = image["image_url"]?.string else {
          throw GatewayProtocolError(400, "invalid_image")
        }
        total += try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes).bytes.count
      }
    }
    if let mask = fields["mask"] {
      guard let url = mask["image_url"]?.string else {
        throw GatewayProtocolError(400, "invalid_mask")
      }
      total += try ImagePayload(dataURL: url, maximumBytes: ImageLimits.imageBytes).bytes.count
    }
    guard total <= ImageLimits.totalImageBytes else {
      throw GatewayProtocolError(413, "image_too_large")
    }
    self.serviceTier = requestMetadataValue(fields["service_tier"])
    self.model = model
    streaming = fields["stream"]?.bool == true
    self.editing = editing
    if let format = fields["output_format"]?.string,
      !["png", "jpeg", "webp"].contains(format)
    {
      guard !editing else { throw GatewayProtocolError(400, "image_format_not_verified") }
      guard let extended = ImageConfiguration.Model.VerifiedOutputFormat(rawValue: format),
        let capability = configuration?.models.first(where: { $0.id == model })
      else { throw GatewayProtocolError(400, "image_format_not_verified") }
      let accounts = Set(
        capability.verifiedGenerationOutputFormatsByAccount.compactMap {
          $0.value.contains(extended) ? $0.key : nil
        })
      guard !accounts.isEmpty else { throw GatewayProtocolError(400, "image_format_not_verified") }
      guard !streaming, fields["partial_images"] == nil, fields["output_compression"] == nil,
        fields["mask"] == nil,
        extended != .svg
          || (!editing && (fields["n"] == nil || fields["n"]?.integer == 1)
            && fields["prompt_rewriter"] == nil)
      else { throw GatewayProtocolError(400, "unsupported_image_format_combination") }
      verifiedAccountIDs = accounts
    } else {
      verifiedAccountIDs = nil
    }
    let missingModel = fields["model"] == nil
    if missingModel { fields["model"] = .string(model) }
    body =
      multipart || missingModel ? try JSONValue.object(fields).data(escapingSlashes: false) : data
  }
}
