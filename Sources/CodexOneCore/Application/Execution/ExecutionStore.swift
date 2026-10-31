import Foundation

public enum ExecutionError: Error, Sendable, Equatable {
  case storagePressure
  case invalidCommand, capacity, denied, conflict, unknownAttempt, unknownObject, ambiguousObject
  case storageUnavailable, incompatibleSchema, instanceLocked, closed, staleEvidence, unauthorized,
    maintenanceRequired
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

public enum ExecutionMode: String, Sendable, Codable { case generation, warmup, compact }

public struct ExecutionAdmission: Sendable, Equatable, Codable {
  public let attempt: String
  public let owner: ExecutionOwner
  public let window: String
  public let policyVersion: String
  public let pricingVersion: String
  /// Operational estimate, not a worst-case bound or subscription balance.
  public let reservedMicros: Int64
  public let requestID: String?
  /// Missing in older admission JSON; interpreted as generation without rewriting history.
  public let model: String?
  public let keyRevision: Int64?
  public let accountSnapshot: AccountDispatchSnapshot?
  public let requirements: ExecutionRequirements?
  public var executionRequirements: ExecutionRequirements { requirements ?? .init() }
  public let mode: ExecutionMode?
  public var executionMode: ExecutionMode { mode ?? .generation }
  public init(
    attempt: String, owner: ExecutionOwner, window: String, policyVersion: String,
    pricingVersion: String, reservedMicros: Int64, requestID: String? = nil,
    mode: ExecutionMode? = nil, keyRevision: Int64? = nil, model: String? = nil,
    accountSnapshot: AccountDispatchSnapshot? = nil, requirements: ExecutionRequirements? = nil
  ) {
    self.requirements = requirements
    self.accountSnapshot = accountSnapshot
    self.attempt = attempt
    self.owner = owner
    self.window = window
    self.policyVersion = policyVersion
    self.pricingVersion = pricingVersion
    self.reservedMicros = reservedMicros
    self.requestID = requestID
    self.mode = mode
    self.keyRevision = keyRevision
    self.model = model
  }
}

public struct ExecutionLimits: Sendable, Equatable, Codable {
  public let requests: Int64?
  public let active: Int64?
  public let unresolved: Int64?
  public let budgetMicros: Int64?
  public let unresolvedMicros: Int64?
  public init(
    requests: Int64?, active: Int64?, unresolved: Int64?, budgetMicros: Int64?,
    unresolvedMicros: Int64?
  ) {
    self.requests = requests
    self.active = active
    self.unresolved = unresolved
    self.budgetMicros = budgetMicros
    self.unresolvedMicros = unresolvedMicros
  }
  /// Existing numeric callers may omit the exposure threshold and inherit the budget.
  public init(requests: Int64, active: Int64, unresolved: Int64, budgetMicros: Int64) {
    self.init(
      requests: requests, active: active, unresolved: unresolved,
      budgetMicros: budgetMicros, unresolvedMicros: budgetMicros)
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case requests, active, unresolved, budgetMicros, unresolvedMicros
  }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    // decode(Optional.self) requires the field while accepting an explicit null.
    requests = try fields.decode(Int64?.self, forKey: .requests)
    active = try fields.decode(Int64?.self, forKey: .active)
    unresolved = try fields.decode(Int64?.self, forKey: .unresolved)
    budgetMicros = try fields.decode(Int64?.self, forKey: .budgetMicros)
    unresolvedMicros = try fields.decode(Int64?.self, forKey: .unresolvedMicros)
  }
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(requests, forKey: .requests)
    try fields.encode(active, forKey: .active)
    try fields.encode(unresolved, forKey: .unresolved)
    try fields.encode(budgetMicros, forKey: .budgetMicros)
    try fields.encode(unresolvedMicros, forKey: .unresolvedMicros)
  }
  public func allows(
    requestCount: Int64, activeCount: Int64, unresolvedCount: Int64,
    exposureMicros: Int64, unresolvedExposureMicros: Int64, reservedMicros: Int64
  ) -> Bool {
    func fits(_ limit: Int64?, _ used: Int64, _ additional: Int64) -> Bool {
      guard let limit else { return true }
      return additional <= limit && used <= limit - additional
    }
    return fits(requests, requestCount, 1) && fits(active, activeCount, 1)
      && fits(unresolved, unresolvedCount, 1)
      && fits(budgetMicros, exposureMicros, reservedMicros)
      && fits(unresolvedMicros, unresolvedExposureMicros, reservedMicros)
  }
}

/// Each observation is a cumulative snapshot for one attempt, not an additive event.
public struct UsageEvidence: Sendable, Equatable, Codable {
  public enum Completeness: String, Sendable, Codable { case partial, complete }
  public let revision: Int64
  public let inputTokens: Int64
  public let outputTokens: Int64
  public let cachedTokens: Int64
  public let imageInputTokens: Int64?
  public let imageOutputTokens: Int64?
  public let nativeImages: Bool?
  public let imageInputTextTokens: Int64?
  public let imageInputImageTokens: Int64?
  public let images: Int64
  public let estimatedMicros: Int64
  public let completeness: Completeness
  public init(
    revision: Int64, inputTokens: Int64, outputTokens: Int64,
    cachedTokens: Int64, images: Int64, estimatedMicros: Int64, completeness: Completeness,
    imageInputTokens: Int64? = nil, imageOutputTokens: Int64? = nil,
    imageInputTextTokens: Int64? = nil, imageInputImageTokens: Int64? = nil,
    nativeImages: Bool? = nil
  ) {
    self.imageInputTokens = imageInputTokens
    self.imageOutputTokens = imageOutputTokens
    self.nativeImages = nativeImages
    self.imageInputTextTokens = imageInputTextTokens
    self.imageInputImageTokens = imageInputImageTokens
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

public struct ObjectBinding: Sendable, Hashable, Codable {
  public let type: String
  public let rawID: String
  public init(type: String, rawID: String) {
    self.type = type
    self.rawID = rawID
  }
}

/// Business commands are each one local transaction. No network call may occur inside them.
public protocol ExecutionStore: Sendable {
  var isAvailable: Bool { get }
  var isAdmissionReady: Bool { get }
  func admit(_ command: ExecutionAdmission) async throws
  func bind(attempt: String, object: ObjectBinding) async throws
  func resolve(principal: String, object: ObjectBinding, namespace: String?) async throws
    -> ExecutionOwner
  func finalize(attempt: String, evidence: UsageEvidence?, outcome: ExecutionOutcome?) async throws
  func snapshot(attempt: String) async throws -> ExecutionSnapshot
}

extension ExecutionStore {
  public var isAdmissionReady: Bool { isAvailable }
  public func finalize(attempt: String, evidence: UsageEvidence?) async throws {
    try await finalize(attempt: attempt, evidence: evidence, outcome: nil)
  }
}

public struct Finalization: Sendable {
  public let attempt: String
  public let evidence: UsageEvidence?
  public let outcome: ExecutionOutcome?
  public init(attempt: String, evidence: UsageEvidence?, outcome: ExecutionOutcome? = nil) {
    self.outcome = outcome
    self.attempt = attempt
    self.evidence = evidence
  }
}

/// Reservation happens synchronously before entering an actor mailbox or creating work.
public protocol FinalizationSink: Sendable {
  var isAccepting: Bool { get }
  func reserve() throws -> UUID
  func canExecute(_ ticket: UUID) -> Bool
  func abandon(_ ticket: UUID)
  func handoff(_ ticket: UUID, finalization: Finalization)
}
