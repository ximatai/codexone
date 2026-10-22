import Foundation

/// Ephemeral plaintext. Never encode this type as a public DTO or diagnostic.
public struct AccountCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let accessToken: String
  public let refreshToken: String
  public let idToken: String?
  public let expiresAtUnixSeconds: Int64
  public var description: String { "AccountCredential(redacted)" }
  public var debugDescription: String { description }

  public init(
    accessToken: String, refreshToken: String, idToken: String?, expiresAtUnixSeconds: Int64
  ) throws {
    let tokens = [accessToken, refreshToken] + (idToken.map { [$0] } ?? [])
    guard
      tokens.allSatisfy({ token in
        !token.isEmpty && token.utf8.count <= 16_384
          && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              || [45, 46, 95, 126, 43, 47, 61].contains($0)
          }
      }), tokens.reduce(0, { $0 + $1.utf8.count }) <= 32_768,
      expiresAtUnixSeconds > 0, expiresAtUnixSeconds <= 1_000_000_000_000
    else { throw ExecutionError.invalidCommand }
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.expiresAtUnixSeconds = expiresAtUnixSeconds
  }
}

/// Authenticated context is immutable; a credential cannot move to another identity or version.
public struct AccountCredentialContext: Sendable, Equatable {
  public let identity: String
  public let namespace: String
  public let version: Int64
  public init(identity: String, namespace: String, version: Int64) throws {
    guard !identity.isEmpty, identity.utf8.count <= 64,
      !namespace.isEmpty, namespace.utf8.count <= 512,
      [identity, namespace].allSatisfy({ $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }),
      (1...1_000_000).contains(version)
    else { throw ExecutionError.invalidCommand }
    self.identity = identity
    self.namespace = namespace
    self.version = version
  }
}
