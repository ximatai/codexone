import Foundation

func imageResult(_ item: JSONValue) throws -> String {
  guard let encoded = item["result"]?.string, !encoded.isEmpty,
    encoded.utf8.count <= ImageLimits.eventBytes,
    let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
    bytes.base64EncodedString() == encoded
  else {
    throw GatewayProtocolError(502, "invalid_upstream_image")
  }
  // Provider output is an opaque bounded artifact, never a reference input or executable.
  // Its format belongs to the provider/client; input codec restrictions do not apply.
  return encoded
}
