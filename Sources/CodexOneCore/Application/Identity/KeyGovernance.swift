import Foundation

public struct KeyPolicy: Sendable, Equatable, Codable {
  public let models: [String]
  public let limits: ExecutionLimits
  public init(models: [String], limits: ExecutionLimits) throws {
    guard !models.isEmpty, models.count <= 32, Set(models).count == models.count,
      models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }),
      [
        limits.requests, limits.active, limits.unresolved, limits.budgetMicros,
        limits.unresolvedMicros,
      ]
      .allSatisfy({ (1...1_000_000_000_000).contains($0) })
    else { throw ExecutionError.invalidCommand }
    self.models = models
    self.limits = limits
  }
  public func validate() throws { _ = try Self(models: models, limits: limits) }
}

/// Safe metadata. Verification material is deliberately absent from list/update responses.
public struct ManagedKey: Sendable, Equatable, Codable {
  public let id: String
  public let principal: String
  public let revision: Int64
  public let enabled: Bool
  public let policy: KeyPolicy
  public let createdAtUnixSeconds: Int64
  public init(
    id: String, principal: String, revision: Int64, enabled: Bool, policy: KeyPolicy,
    createdAtUnixSeconds: Int64
  ) {
    self.id = id
    self.principal = principal
    self.revision = revision
    self.enabled = enabled
    self.policy = policy
    self.createdAtUnixSeconds = createdAtUnixSeconds
  }
}

/// All mutations are local atomic commands. Raw secrets never cross this port.
public protocol KeyGovernanceStore: Sendable {
  func authenticateKey(digest: String) async throws -> ManagedKey
  func createKey(id: String, principal: String, digest: String, policy: KeyPolicy) async throws
    -> ManagedKey
  func updateKey(id: String, revision: Int64, enabled: Bool, policy: KeyPolicy) async throws
    -> ManagedKey
  func rotateKey(id: String, revision: Int64, digest: String) async throws
    -> ManagedKey
  func listKeys(after: String?) async throws -> [ManagedKey]
}
