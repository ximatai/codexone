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
      guard work.credential.idToken != nil,
        work.credential.expiresAtUnixSeconds > Int64(Date().timeIntervalSince1970),
        work.snapshot.credentialVersion == work.account.credentialVersion,
        work.snapshot.revision == work.account.revision,
        work.snapshot.accessExpiresAtUnixSeconds == work.credential.expiresAtUnixSeconds
      else { throw AccountDispatchError.unavailable }
      return SubscriptionDataAccess(
        baseURL: baseURL,
        headers: try verifiedHeaders(account: work.account, credential: work.credential))
    } catch { throw AccountDispatchError.unavailable }
  }
  func quotaAccess(work: AccountObservationWork, target: SubscriptionDataTarget) throws
    -> SubscriptionDataAccess
  {
    let url: String
    switch target {
    case .openAI:
      guard realm == Self.issuer else { throw QuotaObservationFailure.unavailable }
      url = "https://chatgpt.com/backend-api/wham/usage"
    case .syntheticLoopback(let port):
      guard realm.hasPrefix("http://127.0.0.1:"), (1...65535).contains(port) else {
        throw QuotaObservationFailure.unavailable
      }
      url = "http://127.0.0.1:\(port)/backend-api/wham/usage"
    }
    guard work.account.authorization == .ready else { throw QuotaObservationFailure.unavailable }
    do {
      return SubscriptionDataAccess(
        baseURL: url,
        headers: try verifiedHeaders(account: work.account, credential: work.credential))
    } catch { throw QuotaObservationFailure.unavailable }
  }
  private func verifiedHeaders(account: ManagedAccount, credential: AccountCredential) throws
    -> HTTPHeaders
  {
    guard let id = credential.idToken,
      credential.expiresAtUnixSeconds > Int64(Date().timeIntervalSince1970)
    else { throw AccountDispatchError.unavailable }
    let identity = try SubscriptionClaims.idToken(id, nonce: nil, requireCurrent: false)
    let access = try SubscriptionClaims.accessToken(credential.accessToken)
    guard identity.matches(access), try identityNamespace(identity) == account.namespace else {
      throw AccountDispatchError.unavailable
    }
    return [
      "authorization": "Bearer " + credential.accessToken, "chatgpt-account-id": identity.account,
    ]
  }

}
