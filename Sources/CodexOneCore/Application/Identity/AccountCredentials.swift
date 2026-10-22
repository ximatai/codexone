import Foundation

public protocol AccountCredentialProtection: Sendable {
  func seal(_ credential: AccountCredential, context: AccountCredentialContext) throws -> String
  func open(_ envelope: String, context: AccountCredentialContext) throws -> AccountCredential
}
public struct AccountRefreshWork: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let account: ManagedAccount
  public let credential: AccountCredential
  public let intent: String
  public var description: String { "AccountRefreshWork(redacted)" }
  public var debugDescription: String { description }
}

/// Coordinates credential context and durable barriers. Provider verification is an adapter responsibility.
public struct AccountCredentials: Sendable {
  private let store: any AccountGovernanceStore
  private let protection: any AccountCredentialProtection
  public init(store: any AccountGovernanceStore, protection: any AccountCredentialProtection) {
    self.store = store
    self.protection = protection
  }
  public func importVerified(id: String, namespace: String, credential: AccountCredential)
    async throws -> ManagedAccount
  {
    let context = try AccountCredentialContext(identity: id, namespace: namespace, version: 1)
    let envelope = try protection.seal(credential, context: context)
    return try await store.createVerifiedAccount(id: id, namespace: namespace, envelope: envelope)
  }
  public func reauthorizeVerified(
    id: String, revision: Int64, namespace: String, credential: AccountCredential
  ) async throws -> ManagedAccount {
    let old = try await store.accountCredential(id: id).account
    guard old.revision == revision, old.namespace == namespace, old.authorization != .refreshing
    else { throw ExecutionError.conflict }
    let context = try AccountCredentialContext(
      identity: id, namespace: namespace, version: old.credentialVersion + 1)
    return try await store.replaceVerifiedAccountCredential(
      id: id, revision: revision, namespace: namespace,
      envelope: protection.seal(credential, context: context))
  }
  public func beginRefresh(id: String, revision: Int64) async throws -> AccountRefreshWork {
    let old = try await store.accountCredential(id: id)
    guard old.account.revision == revision, old.account.authorization == .ready else {
      throw ExecutionError.conflict
    }
    let context = try AccountCredentialContext(
      identity: id, namespace: old.account.namespace, version: old.account.credentialVersion)
    // Bad keys/ciphertext fail before persisting an intent that could consume a rotating token.
    let credential = try protection.open(old.envelope, context: context)
    let intent = UUID().uuidString
    let pending = try await store.beginAccountRefresh(id: id, revision: revision, intent: intent)
    return AccountRefreshWork(account: pending.account, credential: credential, intent: intent)
  }
  public func finishVerifiedRefresh(
    _ work: AccountRefreshWork, namespace: String, credential: AccountCredential
  ) async throws -> ManagedAccount {
    do {
      guard namespace == work.account.namespace else { throw ExecutionError.conflict }
      let context = try AccountCredentialContext(
        identity: work.account.id, namespace: namespace, version: work.account.credentialVersion + 1
      )
      let envelope = try protection.seal(credential, context: context)
      return try await store.finishAccountRefresh(
        id: work.account.id, credentialVersion: work.account.credentialVersion, intent: work.intent,
        envelope: envelope)
    } catch {
      // The provider may have consumed the token. Failure to write this marker leaves durable intent.
      _ = try? await failRefresh(work)
      throw error
    }
  }
  public func failRefresh(_ work: AccountRefreshWork) async throws -> ManagedAccount {
    try await store.failAccountRefresh(
      id: work.account.id, credentialVersion: work.account.credentialVersion, intent: work.intent)
  }
}
