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
  public static let dispatchRefreshWindowSeconds: Int64 = 5 * 60
  private let now: @Sendable () -> Int64
  private let store: any AccountGovernanceStore
  private let protection: any AccountCredentialProtection
  public init(
    store: any AccountGovernanceStore, protection: any AccountCredentialProtection,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
  ) {
    self.now = now
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
  /// Preparation is not a lease: the store must atomically recheck snapshot at admission.
  public func prepareDispatch(id: String, continuation: Bool) async throws -> AccountDispatchWork {
    let stored = try await store.accountCredential(id: id)
    let account = stored.account
    guard account.authorization == .ready,
      account.mode == .enabled || (account.mode == .draining && continuation)
    else { throw AccountDispatchError.unavailable }
    let context = try AccountCredentialContext(
      identity: id, namespace: account.namespace, version: account.credentialVersion)
    let credential = try protection.open(stored.envelope, context: context)
    guard credential.expiresAtUnixSeconds - now() > Self.dispatchRefreshWindowSeconds else {
      throw AccountDispatchError.refreshRequired
    }
    return try AccountDispatchWork(
      account: account, credential: credential,
      snapshot: AccountDispatchSnapshot(
        revision: account.revision, credentialVersion: account.credentialVersion,
        accessExpiresAtUnixSeconds: credential.expiresAtUnixSeconds, continuation: continuation))
  }
  /// Read-only observation may inspect a disabled account without granting dispatch.
  public func prepareObservation(id: String) async throws -> AccountObservationWork {
    let stored = try await store.accountCredential(id: id)
    guard stored.account.authorization == .ready else { throw QuotaObservationFailure.unavailable }
    let context = try AccountCredentialContext(
      identity: id, namespace: stored.account.namespace, version: stored.account.credentialVersion)
    let credential = try protection.open(stored.envelope, context: context)
    guard credential.expiresAtUnixSeconds > now() else {
      throw QuotaObservationFailure.refreshRequired
    }
    return AccountObservationWork(account: stored.account, credential: credential)
  }
  /// Bounded, local readiness evidence only. Expired access may still use the refresh owner.
  public func hasLocallyRoutableAccount(models: Set<String>? = nil) async throws -> Bool {
    let accounts = try await store.listAccounts(after: nil)
    guard accounts.count <= 64 else { throw ExecutionError.capacity }
    for account in accounts {
      try Task.checkCancellation()
      guard account.mode == .enabled,
        account.authorization == .ready || account.authorization == .refreshing
      else { continue }
      do {
        let stored = try await store.accountCredential(id: account.id)
        guard stored.account.mode == .enabled,
          stored.account.authorization == .ready || stored.account.authorization == .refreshing
        else { continue }
        let context = try AccountCredentialContext(
          identity: stored.account.id,
          namespace: stored.account.namespace, version: stored.account.credentialVersion)
        _ = try protection.open(stored.envelope, context: context)
        if let models, let health = store as? any AccountHealthStore {
          guard
            try await health.hasHealthyModel(
              id: stored.account.id, credentialVersion: stored.account.credentialVersion,
              models: models)
          else { continue }
        }
        return true
      } catch { continue }
    }
    return false
  }
  /// Only expiry metadata leaves this application boundary; plaintext stays transient.
  public func accessExpiresAtUnixSeconds(id: String) async throws -> Int64 {
    let stored = try await store.accountCredential(id: id)
    let context = try AccountCredentialContext(
      identity: id, namespace: stored.account.namespace, version: stored.account.credentialVersion)
    return try protection.open(stored.envelope, context: context).expiresAtUnixSeconds
  }
  public func needsProactiveRefresh(id: String, windowSeconds: Int64) async throws -> Bool {
    let stored = try await store.accountCredential(id: id)
    guard stored.account.mode != .disabled, stored.account.authorization == .ready else {
      return false
    }
    let context = try AccountCredentialContext(
      identity: id, namespace: stored.account.namespace, version: stored.account.credentialVersion)
    let credential = try protection.open(stored.envelope, context: context)
    return credential.expiresAtUnixSeconds - now() <= windowSeconds
  }
  /// Trusted evidence that no rotation completed; never use for ambiguous transport failures.
  public func abandonUncompletedRefresh(_ work: AccountRefreshWork) async throws -> ManagedAccount {
    guard work.credential.expiresAtUnixSeconds > now() else {
      return try await failRefresh(work)
    }
    return try await store.abandonUncompletedAccountRefresh(
      id: work.account.id, credentialVersion: work.account.credentialVersion, intent: work.intent)
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
  public func failRefresh(_ work: AccountRefreshWork, authorizationRequired: Bool = false)
    async throws -> ManagedAccount
  {
    try await store.failAccountRefresh(
      id: work.account.id, credentialVersion: work.account.credentialVersion, intent: work.intent,
      authorizationRequired: authorizationRequired)
  }
}
