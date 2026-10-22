import Foundation

/// Fixed, non-content diagnostics. Only explicit provider statuses affect account health.
public enum ExecutionFailure: String, Sendable, Codable, CaseIterable {
  case authenticationRejected = "authentication_rejected"
  case rateLimited = "rate_limited"
  case upstreamUnavailable = "upstream_unavailable"
  case upstreamRejected = "upstream_rejected"
  case invalidUpstreamResponse = "invalid_upstream_response"
  case deadlineExceeded = "deadline_exceeded"
  case clientCancelled = "client_cancelled"
  case keyRejected = "key_rejected"
  case modelNotAllowed = "model_not_allowed"
  case objectUnavailable = "object_unavailable"
  case objectAmbiguous = "object_ambiguous"
  case localCapacity = "local_capacity"
  case accountUnavailable = "account_unavailable"
  case storageUnavailable = "storage_unavailable"
  case invalidRequest = "invalid_request"
  case indeterminate
}
public struct ExecutionOutcome: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Codable { case succeeded, failed, cancelled }
  public let kind: Kind
  public let failure: ExecutionFailure?
  public let atUnixSeconds: Int64
  public let cooldownSeconds: Int64?
  public init(failure: ExecutionFailure?, atUnixSeconds: Int64, cooldownSeconds: Int64? = nil)
    throws
  {
    guard (1...1_000_000_000_000).contains(atUnixSeconds),
      cooldownSeconds.map({ (1...3600).contains($0) }) ?? true,
      cooldownSeconds == nil || failure == .rateLimited || failure == .upstreamUnavailable
    else { throw ExecutionError.invalidCommand }
    kind = failure == nil ? .succeeded : failure == .clientCancelled ? .cancelled : .failed
    self.failure = failure
    self.atUnixSeconds = atUnixSeconds
    self.cooldownSeconds = cooldownSeconds
  }
  public func validate() throws {
    let copy = try Self(
      failure: failure, atUnixSeconds: atUnixSeconds, cooldownSeconds: cooldownSeconds)
    guard copy.kind == kind else { throw ExecutionError.invalidCommand }
  }
}
public struct AccountModelCooldown: Sendable, Equatable, Codable {
  public let model: String
  public let untilUnixSeconds: Int64
  public let failure: ExecutionFailure
  public init(model: String, untilUnixSeconds: Int64, failure: ExecutionFailure) {
    self.model = model
    self.untilUnixSeconds = untilUnixSeconds
    self.failure = failure
  }
}
public struct AccountHealth: Sendable, Equatable, Codable {
  public let authenticationRejected: Bool
  public let lastFailure: ExecutionFailure?
  public let lastFailureAtUnixSeconds: Int64?
  public let cooldowns: [AccountModelCooldown]
  public init(
    authenticationRejected: Bool, lastFailure: ExecutionFailure?,
    lastFailureAtUnixSeconds: Int64?, cooldowns: [AccountModelCooldown]
  ) {
    self.authenticationRejected = authenticationRejected
    self.lastFailure = lastFailure
    self.lastFailureAtUnixSeconds = lastFailureAtUnixSeconds
    self.cooldowns = cooldowns
  }
}
public protocol AccountHealthStore: AccountGovernanceStore {
  func configureHealthModels(_ models: Set<String>) async throws
  func accountHealth(id: String) async throws -> AccountHealth
  func hasHealthyModel(id: String, credentialVersion: Int64, models: Set<String>) async throws
    -> Bool
}
