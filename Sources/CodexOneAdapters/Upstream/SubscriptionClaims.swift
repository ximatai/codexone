import CodexOneCore
import Foundation

/// These claims are trusted only when received directly from the configured token endpoint over its trusted transport.
/// This is not a JWT-signature verifier and must never authorize arbitrary uploaded/cached JWTs.
struct SubscriptionClaims: Sendable {
  let subject: String
  let account: String
  let user: String?
  let expires: Int64
  func matches(_ other: Self) -> Bool {
    subject == other.subject && account == other.account
      && (user == nil || other.user == nil || user == other.user)
  }
  static func idToken(_ token: String, nonce: String?, requireCurrent: Bool, now: Int64) throws
    -> Self
  {
    let document = try jwt(token)
    let audiences: [String]
    if let audience = document["aud"]?.string {
      audiences = [audience]
    } else if let array = document["aud"]?.array, array.count <= 16,
      array.allSatisfy({ $0.string != nil })
    {
      audiences = array.compactMap(\.string)
    } else {
      throw AccountRefreshError.unavailable
    }
    guard audiences.contains(SubscriptionOAuthProvider.clientID),
      audiences.count == 1 || document["azp"]?.string == SubscriptionOAuthProvider.clientID,
      document["azp"] == nil || document["azp"]?.string == SubscriptionOAuthProvider.clientID
    else { throw AccountRefreshError.unavailable }
    if let nonce {
      guard let returned = document["nonce"]?.string, returned == nonce else {
        throw AccountRefreshError.unavailable
      }
    }
    return try claims(document, requireCurrent: requireCurrent, now: now)
  }
  static func accessToken(_ token: String, now: Int64) throws -> Self {
    try claims(jwt(token), requireCurrent: true, now: now)
  }
  private static func claims(_ document: JSONValue, requireCurrent: Bool, now: Int64) throws -> Self
  {
    guard
      [SubscriptionOAuthProvider.issuer, SubscriptionOAuthProvider.issuer + "/"].contains(
        document["iss"]?.string ?? ""),
      let subject = document["sub"]?.string, valid(subject, maximum: 256),
      let auth = document["https://api.openai.com/auth"],
      let account = auth["chatgpt_account_id"]?.string, valid(account, maximum: 128),
      let expires = document["exp"]?.integer, expires > 0, expires <= 1_000_000_000_000
    else { throw AccountRefreshError.unavailable }
    let user: String?
    if let value = auth["chatgpt_user_id"] ?? auth["user_id"] {
      guard let parsed = value.string, valid(parsed, maximum: 128) else {
        throw AccountRefreshError.unavailable
      }
      user = parsed
    } else {
      user = nil
    }
    if requireCurrent {
      guard expires > now else { throw AccountRefreshError.unavailable }
      for field in ["iat", "nbf"] {
        if let value = document[field] {
          guard let time = value.integer, time >= 0, time <= now + 60 else {
            throw AccountRefreshError.unavailable
          }
        }
      }
    }
    return Self(subject: subject, account: account, user: user, expires: expires)
  }
  private static func valid(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
  }
  private static func jwt(_ token: String) throws -> JSONValue {
    guard token.utf8.count <= 16_384 else { throw AccountRefreshError.unavailable }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw AccountRefreshError.unavailable }
    let decoded = try parts.map { part -> Data in
      guard !part.isEmpty,
        part.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 95].contains($0)
        })
      else { throw AccountRefreshError.unavailable }
      let raw = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
      guard let value = Data(base64Encoded: padded),
        SubscriptionOAuthProvider.base64URL(value) == part
      else { throw AccountRefreshError.unavailable }
      return value
    }
    let header = try JSONValue.decode(decoded[0])
    guard ["RS256", "ES256"].contains(header["alg"]?.string ?? "") else {
      throw AccountRefreshError.unavailable
    }
    let claims = try JSONValue.decode(decoded[1])
    guard claims.object != nil else { throw AccountRefreshError.unavailable }
    return claims
  }
}
