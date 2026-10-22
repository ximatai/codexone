import Foundation

/// Non-secret, durable snapshot checked with execution admission. Never populated from client JSON.
public struct AccountDispatchSnapshot: Sendable, Equatable, Codable {
  public let revision: Int64
  public let credentialVersion: Int64
  public let accessExpiresAtUnixSeconds: Int64
  /// The application has independently established object or connection identity affinity.
  public let continuation: Bool
  public init(
    revision: Int64, credentialVersion: Int64, accessExpiresAtUnixSeconds: Int64,
    continuation: Bool
  ) throws {
    guard (1...1_000_000).contains(revision), (1...1_000_000).contains(credentialVersion),
      (1...1_000_000_000_000).contains(accessExpiresAtUnixSeconds)
    else { throw ExecutionError.invalidCommand }
    self.revision = revision
    self.credentialVersion = credentialVersion
    self.accessExpiresAtUnixSeconds = accessExpiresAtUnixSeconds
    self.continuation = continuation
  }
}
public enum AccountDispatchError: Error, Sendable, Equatable {
  case unavailable, refreshRequired
}
public struct AccountDispatchWork: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let account: ManagedAccount
  public let credential: AccountCredential
  public let snapshot: AccountDispatchSnapshot
  public var description: String { "AccountDispatchWork(redacted)" }
  public var debugDescription: String { description }
  init(account: ManagedAccount, credential: AccountCredential, snapshot: AccountDispatchSnapshot) {
    self.account = account
    self.credential = credential
    self.snapshot = snapshot
  }
}
