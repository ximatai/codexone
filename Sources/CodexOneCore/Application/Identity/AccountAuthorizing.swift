public struct VerifiedAccountAuthorization: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let namespace: String
  public let credential: AccountCredential
  public var description: String { "VerifiedAccountAuthorization(redacted)" }
  public var debugDescription: String { description }
  public init(namespace: String, credential: AccountCredential) {
    self.namespace = namespace
    self.credential = credential
  }
}
public protocol AccountAuthorizationProvider: Sendable {
  func authorizationURL(state: String, nonce: String, verifier: String) throws -> String
  func authorize(code: String, verifier: String, expectedNonce: String) async throws
    -> VerifiedAccountAuthorization
}
public struct AccountAuthorizationStart: Sendable, Encodable {
  public let flowID: String
  public let authorizationURL: String
  public let expiresInSeconds: Int
  public init(flowID: String, authorizationURL: String, expiresInSeconds: Int) {
    self.flowID = flowID
    self.authorizationURL = authorizationURL
    self.expiresInSeconds = expiresInSeconds
  }
}
public enum AccountAuthorizationTarget: Sendable {
  case create
  case reauthorize(id: String, revision: Int64)
}
public protocol AccountAuthorizing: Sendable {
  func begin(owner: String, target: AccountAuthorizationTarget) async throws
    -> AccountAuthorizationStart
  func complete(owner: String, flowID: String, callbackURL: String) async throws -> ManagedAccount
  func discard(owner: String, flowID: String) async
}
