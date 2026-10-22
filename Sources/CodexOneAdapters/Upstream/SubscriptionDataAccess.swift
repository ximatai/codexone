import CodexOneCore
import Foundation
import NIOHTTP1

/// Chosen only by trusted assembly. No production configuration URL override.
enum SubscriptionDataTarget: Sendable {
  case openAI
  case syntheticLoopback(port: Int)
}
struct SubscriptionDataAccess: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let baseURL: String
  let headers: HTTPHeaders
  var description: String { "SubscriptionDataAccess(redacted)" }
  var debugDescription: String { description }
}
extension SubscriptionOAuthProvider {
  /// Only sealed, provider-verified work may reach this port; never arbitrary client JWTs.
  func dataAccess(work: AccountDispatchWork, target: SubscriptionDataTarget = .openAI) throws
    -> SubscriptionDataAccess
  {
    let baseURL: String
    switch target {
    case .openAI:
      guard realm == Self.issuer else { throw AccountDispatchError.unavailable }
      baseURL = Self.dataOrigin
    case .syntheticLoopback(let port):
      guard realm.hasPrefix("http://127.0.0.1:"), (1...65535).contains(port) else {
        throw AccountDispatchError.unavailable
      }
      baseURL = "http://127.0.0.1:\(port)/backend-api/codex"
    }
    do {
      guard let id = work.credential.idToken,
        work.credential.expiresAtUnixSeconds > Int64(Date().timeIntervalSince1970),
        work.snapshot.credentialVersion == work.account.credentialVersion,
        work.snapshot.revision == work.account.revision,
        work.snapshot.accessExpiresAtUnixSeconds == work.credential.expiresAtUnixSeconds
      else { throw AccountDispatchError.unavailable }
      let identity = try SubscriptionClaims.idToken(id, nonce: nil, requireCurrent: false)
      let access = try SubscriptionClaims.accessToken(work.credential.accessToken)
      guard identity.matches(access), try identityNamespace(identity) == work.account.namespace
      else {
        throw AccountDispatchError.unavailable
      }
      return SubscriptionDataAccess(
        baseURL: baseURL,
        headers: [
          "authorization": "Bearer " + work.credential.accessToken,
          "chatgpt-account-id": identity.account,
        ])
    } catch { throw AccountDispatchError.unavailable }
  }
}
