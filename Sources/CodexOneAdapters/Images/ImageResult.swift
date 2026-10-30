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
