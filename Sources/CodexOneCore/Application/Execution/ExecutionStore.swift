import Foundation

public enum ExecutionError: Error, Sendable, Equatable {
  case invalidCommand, capacity, denied, conflict, unknownAttempt, unknownObject, ambiguousObject
  case storageUnavailable, incompatibleSchema, instanceLocked, closed, staleEvidence
}

/// Trusted application identity; never populated directly from client claims.
public struct ExecutionOwner: Sendable, Equatable, Codable {
  public let principal: String
  public let key: String
  public let namespace: String
  public let identity: String
  public init(principal: String, key: String, namespace: String, identity: String) {
    self.principal = principal
    self.key = key
    self.namespace = namespace
    self.identity = identity
  }
}

public struct ExecutionAdmission: Sendable, Equatable, Codable {
  public let attempt: String
  public let owner: ExecutionOwner
  public let window: String
  public let policyVersion: String
  public let pricingVersion: String
  /// Operational estimate, not a worst-case bound or subscription balance.
  public let reservedMicros: Int64
  public init(
    attempt: String, owner: ExecutionOwner, window: String, policyVersion: String,
    pricingVersion: String, reservedMicros: Int64
  ) {
    self.attempt = attempt
    self.owner = owner
    self.window = window
    self.policyVersion = policyVersion
    self.pricingVersion = pricingVersion
    self.reservedMicros = reservedMicros
  }
}

public struct ExecutionLimits: Sendable, Equatable, Codable {
  public let requests: Int64
  public let active: Int64
  public let unresolved: Int64
  public let budgetMicros: Int64
  public let unresolvedMicros: Int64
  public init(
    requests: Int64, active: Int64, unresolved: Int64, budgetMicros: Int64,
    unresolvedMicros: Int64? = nil
  ) {
    self.requests = requests
    self.active = active
    self.unresolved = unresolved
    self.budgetMicros = budgetMicros
    self.unresolvedMicros = unresolvedMicros ?? budgetMicros
  }
}

/// Each observation is a cumulative snapshot for one attempt, not an additive event.
public struct UsageEvidence: Sendable, Equatable, Codable {
  public enum Completeness: String, Sendable, Codable { case partial, complete }
  public let revision: Int64
  public let inputTokens: Int64
  public let outputTokens: Int64
  public let cachedTokens: Int64
  public let images: Int64
  public let estimatedMicros: Int64
  public let completeness: Completeness
  public init(
    revision: Int64, inputTokens: Int64, outputTokens: Int64,
    cachedTokens: Int64, images: Int64, estimatedMicros: Int64, completeness: Completeness
  ) {
    self.revision = revision
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.images = images
    self.estimatedMicros = estimatedMicros
    self.completeness = completeness
  }
}

public struct ExecutionSnapshot: Sendable, Equatable, Codable {
  public enum State: String, Sendable, Codable { case intent, unknown, settled }
  public let admission: ExecutionAdmission
  public let state: State
  public let usage: UsageEvidence?
  public init(admission: ExecutionAdmission, state: State, usage: UsageEvidence?) {
    self.admission = admission
    self.state = state
    self.usage = usage
  }
}

public struct ObjectBinding: Sendable, Equatable, Codable {
  public let type: String
  public let rawID: String
  public init(type: String, rawID: String) {
    self.type = type
    self.rawID = rawID
  }
}

/// Business commands are each one local transaction. No network call may occur inside them.
public protocol ExecutionStore: Sendable {
  func admit(_ command: ExecutionAdmission) async throws
  func bind(attempt: String, object: ObjectBinding) async throws
  func resolve(principal: String, object: ObjectBinding, namespace: String?) async throws
    -> ExecutionOwner
  func finalize(attempt: String, evidence: UsageEvidence?) async throws
  func snapshot(attempt: String) async throws -> ExecutionSnapshot
}

public struct Finalization: Sendable {
  public let attempt: String
  public let evidence: UsageEvidence?
  public init(attempt: String, evidence: UsageEvidence?) {
    self.attempt = attempt
    self.evidence = evidence
  }
}

/// Reservation happens synchronously before entering an actor mailbox or creating work.
public protocol FinalizationSink: Sendable {
  func reserve() throws -> UUID
  func canExecute(_ ticket: UUID) -> Bool
  func abandon(_ ticket: UUID)
  func handoff(_ ticket: UUID, finalization: Finalization)
}
