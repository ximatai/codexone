import Foundation

public struct AccountRouteIdentity: Sendable, Hashable {
  public let id: String
  public let namespace: String
  public init(id: String, namespace: String) throws {
    _ = try AccountCredentialContext(identity: id, namespace: namespace, version: 1)
    guard ManagedAccount.validID(id) else { throw ExecutionError.invalidCommand }
    self.id = id
    self.namespace = namespace
  }
}
/// Current managed Key policy plus the deployment's explicit common model/profile range.
public struct AccountPoolPolicy: Sendable {
  public let key: ManagedKey
  public let models: Set<String>
  public let reservedMicros: Int64
  public let policyVersion: String
  public let pricingVersion: String
  public init(
    key: ManagedKey, models: Set<String>, reservedMicros: Int64, policyVersion: String,
    pricingVersion: String
  ) throws {
    guard key.enabled, key.archivedAtUnixSeconds == nil, models.count <= 48,
      models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      [policyVersion, pricingVersion].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      (0...1_000_000_000_000).contains(reservedMicros)
    else { throw ExecutionError.invalidCommand }
    self.key = key
    self.models = models.filter { key.policy.allowsConfiguredModel($0) }
    self.reservedMicros = reservedMicros
    self.policyVersion = policyVersion
    self.pricingVersion = pricingVersion
  }
}
public struct AccountRouteCandidate: Sendable {
  public let identity: AccountRouteIdentity
  public let snapshot: AccountDispatchSnapshot
  public init(work: AccountDispatchWork) throws {
    identity = try AccountRouteIdentity(id: work.account.id, namespace: work.account.namespace)
    snapshot = work.snapshot
  }
}
/// Local transaction input only. Does not contain plaintext credentials.
public struct AccountPoolAdmission: Sendable {
  public let attempt: String
  public let policy: AccountPoolPolicy
  public let model: String
  public let window: String
  public let requestID: String?
  public let mode: ExecutionMode
  public let references: [ObjectBinding]
  public let connection: AccountRouteIdentity?
  public let requirements: ExecutionRequirements
  public let reasoningEffort: String?
  public let serviceTier: String?
  public let candidates: [AccountRouteCandidate]
  public init(
    attempt: String, policy: AccountPoolPolicy, model: String, window: String, requestID: String?,
    mode: ExecutionMode, references: [ObjectBinding], connection: AccountRouteIdentity?,
    candidates: [AccountRouteCandidate], requirements: ExecutionRequirements = .init(),
    reasoningEffort: String? = nil, serviceTier: String? = nil
  ) throws {
    guard !attempt.isEmpty, attempt.utf8.count <= 256, !window.isEmpty, window.utf8.count <= 256,
      policy.models.contains(model),
      policy.key.policy.allows(model: model, requirements: requirements), references.count <= 32,
      (1...64).contains(candidates.count),
      Set(candidates.map(\.identity)).count == candidates.count,
      Set(candidates.map(\.identity.id)).count == candidates.count
    else { throw ExecutionError.invalidCommand }
    self.reasoningEffort = reasoningEffort
    self.serviceTier = serviceTier
    self.requirements = requirements
    self.attempt = attempt
    self.policy = policy
    self.model = model
    self.window = window
    self.requestID = requestID
    self.mode = mode
    self.references = references
    self.connection = connection
    self.candidates = candidates
  }
  public func selecting(_ candidate: AccountRouteCandidate) -> ExecutionAdmission {
    ExecutionAdmission(
      attempt: attempt,
      owner: .init(
        principal: policy.key.principal, key: policy.key.id,
        namespace: candidate.identity.namespace, identity: candidate.identity.id),
      window: window, policyVersion: policy.policyVersion, pricingVersion: policy.pricingVersion,
      reservedMicros: policy.reservedMicros, requestID: requestID, mode: mode,
      keyRevision: policy.key.revision, model: model, accountSnapshot: candidate.snapshot,
      requirements: requirements, reasoningEffort: reasoningEffort, serviceTier: serviceTier)
  }
}
public struct PreparedAccountPoolAdmission: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let command: AccountPoolAdmission
  public let credentials: [AccountRouteIdentity: AccountDispatchWork]
  public var description: String { "PreparedAccountPoolAdmission(redacted)" }
  public var debugDescription: String { description }
  public init(
    command: AccountPoolAdmission, credentials: [AccountRouteIdentity: AccountDispatchWork]
  )
    throws
  {
    guard credentials.count == command.candidates.count,
      command.candidates.allSatisfy({ candidate in
        guard let work = credentials[candidate.identity] else { return false }
        return work.account.id == candidate.identity.id
          && work.account.namespace == candidate.identity.namespace
          && work.snapshot == candidate.snapshot
      })
    else { throw ExecutionError.invalidCommand }
    self.command = command
    self.credentials = credentials
  }
}
public protocol AccountRoutingStore: ExecutionStore, AccountGovernanceStore {
  func selectControlAccount(
    key: ManagedKey, candidates: [AccountRouteCandidate], preferred: AccountRouteIdentity?
  ) async throws -> AccountRouteIdentity
  func recordControlOutcome(account: AccountRouteCandidate, outcome: ExecutionOutcome) async throws

  func resolveAccountAffinity(
    principal: String, references: [ObjectBinding], connection: AccountRouteIdentity?
  ) async throws -> AccountRouteIdentity?
  func admitSelectingAccount(_ command: AccountPoolAdmission) async throws -> ExecutionAdmission
  /// The account owning the most recent resolvable soft history label, if any.
  func resolveAccountHint(principal: String, hints: [ObjectBinding]) async throws
    -> AccountRouteIdentity?
}

extension AccountRoutingStore {
  public func selectControlAccount(
    key: ManagedKey, candidates: [AccountRouteCandidate], preferred: AccountRouteIdentity?
  ) async throws -> AccountRouteIdentity {
    throw AccountDispatchError.unavailable
  }
  public func recordControlOutcome(account: AccountRouteCandidate, outcome: ExecutionOutcome)
    async throws
  {
    throw ExecutionError.storageUnavailable
  }

  public func resolveAccountHint(principal: String, hints: [ObjectBinding]) async throws
    -> AccountRouteIdentity?
  { nil }
}
