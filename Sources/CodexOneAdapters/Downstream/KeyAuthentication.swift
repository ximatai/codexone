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
  let source: ResponsesSource
  let token: String?
  let store: any ExecutionStore
  let finalizer: any FinalizationSink

  func digest(_ headers: [String]) throws -> String? {
    if case .single(let configuration) = source, configuration.managedKeys != true {
      guard configuration.accepts(headers) else { throw ExecutionError.unauthorized }
      return nil
    }
    return try bearerDigest(headers)
  }
  func policy(_ digest: String?) async throws -> ResponsesPolicy {
    if case .single(let configuration) = source, configuration.managedKeys != true {
      return .single(try configuration.makePolicy(token: token))
    }
    guard let digest, let keys = store as? any KeyGovernanceStore else {
      throw ExecutionError.unauthorized
    }
    let key = try await keys.authenticateKey(digest: digest)
    switch source {
    case .single(let configuration):
      return .single(try configuration.makePolicy(token: token, key: key))
    case .pool(let configuration, _, _, _, _): return .pool(try configuration.policy(key: key))
    }
  }
  func gateway(_ policy: ResponsesPolicy) throws -> ResponsesGateway {
    switch (source, policy) {
    case (.single, .single(let policy)):
      return .single(.init(policy: policy, store: store, finalizer: finalizer))
    case (.pool(_, let credentials, let refresher, let provider, let target), .pool(let policy)):
      guard let routing = store as? any AccountRoutingStore else {
        throw ExecutionError.invalidCommand
      }
      return .pool(
        .init(
          policy: policy, store: routing, credentials: credentials, finalizer: finalizer,
          refresher: refresher), provider, target)
    default: throw ExecutionError.invalidCommand
    }
  }
}
