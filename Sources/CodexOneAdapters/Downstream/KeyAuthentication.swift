import CodexOneCore
import Crypto
import Foundation

func bearerDigest(_ headers: [String]) throws -> String {
  guard headers.count == 1, headers[0].hasPrefix("Bearer ") else {
    throw ExecutionError.unauthorized
  }
  let value = String(headers[0].dropFirst(7))
  guard (24...512).contains(value.utf8.count), value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
    throw ExecutionError.unauthorized
  }
  return keyDigest(value)
}
func keyDigest(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
func generateKeySecret() -> String {
  var generator = SystemRandomNumberGenerator()
  return "co1_"
    + Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    .base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
struct DataPlaneAuthorization: Sendable {
  let configuration: SingleIdentityConfiguration
  let token: String?
  let store: any ExecutionStore
  let finalizer: any FinalizationSink

  func digest(_ headers: [String]) throws -> String? {
    if configuration.managedKeys == true { return try bearerDigest(headers) }
    guard configuration.accepts(headers) else { throw ExecutionError.unauthorized }
    return nil
  }
  func policy(_ digest: String?) async throws -> SingleIdentityPolicy {
    let key: ManagedKey?
    if configuration.managedKeys == true {
      guard let digest, let keys = store as? any KeyGovernanceStore else {
        throw ExecutionError.unauthorized
      }
      key = try await keys.authenticateKey(digest: digest)
    } else {
      key = nil
    }
    return try configuration.makePolicy(token: token, key: key)
  }
}
