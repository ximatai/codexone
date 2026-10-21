import Foundation

public struct SingleIdentityPolicy: Sendable {
  public let owner: ExecutionOwner
  public let models: Set<String>
  public let reservedMicros: Int64
  public let policyVersion: String
  public let pricingVersion: String
  public init(
    owner: ExecutionOwner, models: Set<String>, reservedMicros: Int64, policyVersion: String,
    pricingVersion: String
  ) throws {
    guard [policyVersion, pricingVersion].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      !models.isEmpty, models.count <= 32,
      models.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      (0...1_000_000_000_000).contains(reservedMicros)
    else { throw ExecutionError.invalidCommand }
    self.owner = owner
    self.models = models
    self.reservedMicros = reservedMicros
    self.policyVersion = policyVersion
    self.pricingVersion = pricingVersion
  }
}

/// Application authorization owns object checks and durable admission, independent of wire transport.
public struct SingleIdentityGateway: Sendable {
  private let policy: SingleIdentityPolicy
  private let store: any ExecutionStore
  private let coordinator: ExecutionCoordinator
  public init(
    policy: SingleIdentityPolicy, store: any ExecutionStore, finalizer: any FinalizationSink
  ) {
    self.policy = policy
    self.store = store
    coordinator = .init(store: store, finalizer: finalizer)
  }
  public func execute(
    model: String, references: [ObjectBinding], requestID: String? = nil,
    mode: ExecutionMode = .generation,
    operation: @Sendable (ExecutionContext) async throws -> UsageEvidence?
  ) async throws {
    guard policy.models.contains(model), references.count <= 32 else { throw ExecutionError.denied }
    for reference in references {
      let owner = try await store.resolve(
        principal: policy.owner.principal, object: reference, namespace: policy.owner.namespace)
      guard owner.namespace == policy.owner.namespace, owner.identity == policy.owner.identity
      else {
        throw ExecutionError.unknownObject
      }
    }
    // UTC daily admission window; the persisted policy/pricing snapshots explain its interpretation.
    let day = Int64(Date().timeIntervalSince1970 / 86_400)
    let admission = ExecutionAdmission(
      attempt: UUID().uuidString, owner: policy.owner,
      window: "utc-day-\(day)", policyVersion: policy.policyVersion,
      pricingVersion: policy.pricingVersion,
      reservedMicros: policy.reservedMicros, requestID: requestID, mode: mode)
    try await coordinator.execute(admission, operation: operation)
  }
}
