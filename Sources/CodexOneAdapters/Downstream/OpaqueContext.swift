import CodexOneCore
import Crypto
import Foundation

/// Private provider context remains wire-only; persist only a type-separated ownership fingerprint.
func opaqueContext(_ value: JSONValue?, kind: String) throws -> ObjectBinding? {
  guard let value, value != .null else { return nil }
  guard let encrypted = value.string, !encrypted.isEmpty, encrypted.utf8.count <= 196_608 else {
    throw GatewayProtocolError(400, "invalid_private_context")
  }
  let digest = SHA256.hash(data: Data(encrypted.utf8)).map { String(format: "%02x", $0) }.joined()
  return .init(type: "context_" + kind, rawID: digest)
}
