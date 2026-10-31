import Foundation

public enum AccountMode: String, Sendable, Codable { case enabled, draining, disabled }
public enum AccountAuthorization: String, Sendable, Codable {
  case ready, refreshing
  case requiresAuth = "requires_auth"
  case authUncertain = "auth_uncertain"
}
public struct ManagedAccount: Sendable, Equatable, Encodable {
  public let displayName: String?
  public let id: String
  public let namespace: String
  public let revision: Int64
  public let credentialVersion: Int64
  public let mode: AccountMode
  public let authorization: AccountAuthorization
  public let refreshIntent: String?
  public let createdAtUnixSeconds: Int64

  public init(
    id: String, namespace: String, revision: Int64, credentialVersion: Int64,
    mode: AccountMode, authorization: AccountAuthorization, refreshIntent: String?,
    createdAtUnixSeconds: Int64, displayName: String? = nil
  ) throws {
    _ = try AccountCredentialContext(identity: id, namespace: namespace, version: credentialVersion)
    guard Self.validID(id), (1...1_000_000).contains(revision), createdAtUnixSeconds > 0,
      refreshIntent == nil || Self.validID(refreshIntent!),
      authorization != .refreshing || refreshIntent != nil,
      authorization != .ready || refreshIntent == nil
    else { throw ExecutionError.invalidCommand }
    try Self.validateDisplayName(displayName)
    self.displayName = displayName
    self.id = id
    self.namespace = namespace
    self.revision = revision
    self.credentialVersion = credentialVersion
    self.mode = mode
    self.authorization = authorization
    self.refreshIntent = refreshIntent
    self.createdAtUnixSeconds = createdAtUnixSeconds
  }
  public static func validateDisplayName(_ value: String?) throws {
    guard
      value.map({
        (1...64).contains($0.unicodeScalars.count) && $0.utf8.count <= 256
          && !$0.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
              || CharacterSet.illegalCharacters.contains($0)
              || $0.properties.generalCategory == .format
              || $0.properties.generalCategory == .lineSeparator
              || $0.properties.generalCategory == .paragraphSeparator
          }
      }) ?? true
    else { throw ExecutionError.invalidCommand }
  }
  public static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }
  }
}
/// Internal application value; the envelope is never returned by management DTOs.
public struct StoredAccountCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let account: ManagedAccount
  public let envelope: String
  public var description: String { "StoredAccountCredential(redacted)" }
  public var debugDescription: String { description }
  public init(account: ManagedAccount, envelope: String) {
    self.account = account
    self.envelope = envelope
  }
}

/// Only verified provider responses may enter this application port; no unverified JWT import.
public protocol AccountGovernanceStore: Sendable {
  func createVerifiedAccount(id: String, namespace: String, envelope: String) async throws
    -> ManagedAccount
  func accountCredential(id: String) async throws -> StoredAccountCredential
  func listAccounts(after: String?) async throws -> [ManagedAccount]
  func setAccountDisplayName(id: String, revision: Int64, displayName: String?) async throws
    -> ManagedAccount
  func setAccountMode(id: String, revision: Int64, mode: AccountMode) async throws -> ManagedAccount
  func beginAccountRefresh(id: String, revision: Int64, intent: String) async throws
    -> StoredAccountCredential
  func finishAccountRefresh(id: String, credentialVersion: Int64, intent: String, envelope: String)
    async throws -> ManagedAccount
  func failAccountRefresh(
    id: String, credentialVersion: Int64, intent: String, authorizationRequired: Bool
  ) async throws
    -> ManagedAccount
  func abandonUncompletedAccountRefresh(id: String, credentialVersion: Int64, intent: String)
    async throws -> ManagedAccount
  /// Non-secret durable commit audit time; missing evidence is unavailable.
  func credentialUpdatedAtUnixSeconds(id: String) async throws -> Int64?
  func replaceVerifiedAccountCredential(
    id: String, revision: Int64, namespace: String, envelope: String
  ) async throws -> ManagedAccount
}
